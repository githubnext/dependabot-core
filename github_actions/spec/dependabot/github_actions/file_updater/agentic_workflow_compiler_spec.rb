# typed: strict
# frozen_string_literal: true

require "spec_helper"
require "dependabot/github_actions/file_updater/agentic_workflow_compiler"

RSpec.describe Dependabot::GithubActions::FileUpdater::AgenticWorkflowCompiler do
  extend T::Sig

  sig { returns(Dependabot::GithubActions::FileUpdater::AgenticWorkflowCompiler) } # rubocop:disable RSpec/DescribedClass -- Concrete Sorbet type.
  subject(:compiler) { described_class.new(credentials: [], repository: "gocardless/bump") }

  # rubocop:disable RSpec/ScatteredLet -- Keep Sorbet signatures immediately before their lets.
  sig { returns(Dependabot::DependencyFile) }
  let(:markdown) do
    Dependabot::DependencyFile.new(
      name: ".github/workflows/agentic.md",
      content: fixture("workflow_files", "agentic.md").sub("setup-node@v4", "setup-node@v5")
    )
  end

  sig { returns(Dependabot::DependencyFile) }
  let(:lockfile) do
    Dependabot::DependencyFile.new(
      name: ".github/workflows/agentic.lock.yml",
      content: fixture("workflow_files", "agentic.lock.yml"),
      support_file: true
    )
  end

  sig { returns(String) }
  let!(:compiled_content) { fixture("workflow_files", "agentic_updated.lock.yml") }

  sig { returns(Dependabot::DependencyFile) }
  let(:cache) do
    Dependabot::DependencyFile.new(
      name: ".github/aw/actions-lock.json",
      content: "{\"entries\":{}}\n",
      support_file: true,
      mode: Dependabot::DependencyFile::Mode::FILE
    )
  end
  # rubocop:enable RSpec/ScatteredLet

  before do
    allow(Dependabot::CommandHelpers).to receive(:capture3_with_timeout).and_call_original
  end

  sig { params(cache_content: T.nilable(String)).void }
  def stub_successful_compilation(cache_content: nil)
    allow(Dependabot::CommandHelpers).to receive(:capture3_with_timeout).with(array_including("compile")) do |args|
      root = args.last.fetch(:chdir)
      File.write(File.join(root, lockfile.path.delete_prefix("/")), compiled_content)
      if cache_content
        path = File.join(root, ".github/aw/actions-lock.json")
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, cache_content)
      end
      ["", "", Dependabot::CommandHelpers::ProcessStatus.new(nil, 0)]
    end
  end

  it "compiles in repository layout and preserves the schedule seed" do
    allow(Dependabot::CommandHelpers).to receive(:capture3_with_timeout).with(array_including("compile")) do |args|
      root = args.last.fetch(:chdir)
      expect(File.directory?(File.join(root, ".git"))).to be(true)
      expect(File.read(File.join(root, markdown.name))).to eq(markdown.content)
      File.write(File.join(root, lockfile.name), compiled_content)
      ["", "", Dependabot::CommandHelpers::ProcessStatus.new(nil, 0)]
    end

    files = compiler.compile(files: [markdown, lockfile], workflows: [markdown])
    expect(T.must(files.first).content).to eq(compiled_content)
    expect(T.must(files.first).support_file?).to be(false)
    expect(Dependabot::CommandHelpers).to have_received(:capture3_with_timeout).with(
      [hash_including("GH_PROMPT_DISABLED" => "1"), "gh", "aw", "compile",
       "--schedule-seed", "gocardless/bump", "--fix", "--no-check-update", "--dir", ".github/workflows",
       "--", "agentic.md", anything]
    )
  end

  it "returns Markdown migrations made by compile --fix" do
    migrated_content = T.must(markdown.content).sub('node-version: "22"', 'node-version: "24"')
    allow(Dependabot::CommandHelpers).to receive(:capture3_with_timeout).with(array_including("compile")) do |args|
      root = args.last.fetch(:chdir)
      File.write(File.join(root, lockfile.name), compiled_content)
      File.write(File.join(root, markdown.name), migrated_content)
      ["", "", Dependabot::CommandHelpers::ProcessStatus.new(nil, 0)]
    end

    files = compiler.compile(files: [markdown, lockfile], workflows: [markdown])

    expect(files.find { |file| file.name == markdown.name }&.content).to eq(migrated_content)
    expect(markdown.content).not_to eq(migrated_content)
  end

  it "compiles each affected workflow without returning unrelated lockfiles" do
    second = markdown.dup
    second.name = ".github/workflows/second.md"
    second_lock = lockfile.dup
    second_lock.name = ".github/workflows/second.lock.yml"
    untouched = lockfile.dup
    untouched.name = ".github/workflows/untouched.lock.yml"
    allow(Dependabot::CommandHelpers).to receive(:capture3_with_timeout).with(array_including("compile")) do |args|
      path = File.join(args.last.fetch(:chdir), ".github/workflows", args[-2].sub(/\.md\z/, ".lock.yml"))
      File.write(path, compiled_content)
      ["", "", Dependabot::CommandHelpers::ProcessStatus.new(nil, 0)]
    end

    files = compiler.compile(
      files: [markdown, lockfile, second, second_lock, untouched], workflows: [markdown, second]
    )

    expect(files.map(&:name)).to contain_exactly(lockfile.name, second_lock.name)
    expect(files.map(&:content)).to all(eq(compiled_content))
  end

  it "does not return partial results when a later workflow fails" do
    second = markdown.dup
    second.name = ".github/workflows/second.md"
    second_lock = lockfile.dup
    second_lock.name = ".github/workflows/second.lock.yml"
    original_content = lockfile.content
    allow(Dependabot::CommandHelpers).to receive(:capture3_with_timeout).with(array_including("compile")) do |args|
      if args[-2] == "second.md"
        ["", "second workflow is invalid", Dependabot::CommandHelpers::ProcessStatus.new(nil, 1)]
      else
        File.write(File.join(args.last.fetch(:chdir), lockfile.name), compiled_content)
        ["", "", Dependabot::CommandHelpers::ProcessStatus.new(nil, 0)]
      end
    end

    expect do
      compiler.compile(files: [markdown, lockfile, second, second_lock], workflows: [markdown, second])
    end.to raise_error(Dependabot::DependencyFileNotResolvable, /second workflow is invalid/)
    expect(lockfile.content).to eq(original_content)
  end

  it "returns new action pin caches as primary update files" do
    stub_successful_compilation(cache_content: "{\"entries\":{}}\n")
    files = compiler.compile(files: [markdown, lockfile], workflows: [markdown])
    cache = files.find { |file| file.path == "/.github/aw/actions-lock.json" }
    expect(cache&.content).to eq("{\"entries\":{}}\n")
    expect(cache&.support_file?).to be(false)
  end

  it "preserves compilation inputs and omits an unchanged cache" do
    imported = Dependabot::DependencyFile.new(
      name: ".github/workflows/shared/tools.md", content: "---\ntools:\n  bash: true\n---\n"
    )
    config = Dependabot::DependencyFile.new(name: ".github/workflows/aw.json", content: "{}\n", support_file: true)
    allow(Dependabot::CommandHelpers).to receive(:capture3_with_timeout).with(array_including("compile")) do |args|
      root = args.last.fetch(:chdir)
      expect(File.read(File.join(root, imported.name))).to eq(imported.content)
      expect(File.read(File.join(root, config.name))).to eq(config.content)
      expect(File.read(File.join(root, cache.name))).to eq(cache.content)
      File.write(File.join(root, lockfile.name), compiled_content)
      ["", "", Dependabot::CommandHelpers::ProcessStatus.new(nil, 0)]
    end

    files = compiler.compile(files: [markdown, lockfile, imported, config, cache], workflows: [markdown])

    expect(files.map(&:name)).to eq([lockfile.name])
  end

  it "returns changed caches without mutating their original content or file metadata" do
    new_content = "{\"entries\":{\"actions/setup-node@v5\":{\"sha\":\"new-pin\"}}}\n"
    original_content = cache.content
    stub_successful_compilation(cache_content: new_content)
    files = compiler.compile(files: [markdown, lockfile, cache], workflows: [markdown])
    updated_cache = T.must(files.find { |file| file.name == cache.name })

    expect(updated_cache.content).to eq(new_content)
    expect(updated_cache.mode).to eq(cache.mode)
    expect(updated_cache.support_file?).to be(false)
    expect(cache.content).to eq(original_content)
    expect(cache.support_file?).to be(true)
  end

  context "with an explicit workflow directory" do
    # rubocop:disable RSpec/ScatteredLet -- Keep Sorbet signatures immediately before their lets.
    sig { returns(Dependabot::DependencyFile) }
    let(:markdown) do
      Dependabot::DependencyFile.new(
        name: "agentic.md",
        directory: "/.github/workflows",
        content: fixture("workflow_files", "agentic.md").sub("setup-node@v4", "setup-node@v5")
      )
    end

    sig { returns(Dependabot::DependencyFile) }
    let(:lockfile) do
      Dependabot::DependencyFile.new(
        name: "agentic.lock.yml",
        directory: "/.github/workflows",
        content: fixture("workflow_files", "agentic.lock.yml"),
        support_file: true
      )
    end
    # rubocop:enable RSpec/ScatteredLet

    it "returns the lockfile and new cache relative to the configured directory" do
      stub_successful_compilation(cache_content: "{\"entries\":{}}\n")
      files = compiler.compile(files: [markdown, lockfile], workflows: [markdown])

      expect(files.map(&:path)).to contain_exactly(
        "/.github/workflows/agentic.lock.yml", "/.github/aw/actions-lock.json"
      )
      expect(files.map(&:directory)).to all(eq("/.github/workflows"))
    end
  end

  it "surfaces compiler errors without returning partially updated files" do
    allow(Dependabot::CommandHelpers).to receive(:capture3_with_timeout)
      .with(array_including("compile"))
      .and_return(["", "invalid frontmatter", Dependabot::CommandHelpers::ProcessStatus.new(nil, 1)])
    expect { compiler.compile(files: [markdown, lockfile], workflows: [markdown]) }
      .to raise_error(Dependabot::DependencyFileNotResolvable, /invalid frontmatter/)
  end

  it "surfaces a failure to start the compiler" do
    allow(Dependabot::CommandHelpers).to receive(:capture3_with_timeout)
      .with(array_including("compile"))
      .and_return(["", "No such file", nil])
    expect { compiler.compile(files: [markdown, lockfile], workflows: [markdown]) }
      .to raise_error(Dependabot::DependencyFileNotResolvable, /No such file/)
  end

  it "does not mistake an existing lockfile for successful regeneration" do
    allow(Dependabot::CommandHelpers).to receive(:capture3_with_timeout)
      .with(array_including("compile"))
      .and_return(["", "", Dependabot::CommandHelpers::ProcessStatus.new(nil, 0)])
    expect { compiler.compile(files: [markdown, lockfile], workflows: [markdown]) }
      .to raise_error(Dependabot::DependencyFileNotResolvable, /did not regenerate/)
  end

  it "rejects a successful exit that leaves no generated workflow" do
    allow(Dependabot::CommandHelpers).to receive(:capture3_with_timeout).with(array_including("compile")) do |args|
      File.delete(File.join(args.last.fetch(:chdir), lockfile.name))
      ["", "", Dependabot::CommandHelpers::ProcessStatus.new(nil, 0)]
    end

    expect { compiler.compile(files: [markdown, lockfile], workflows: [markdown]) }
      .to raise_error(Dependabot::DependencyFileNotResolvable, /did not produce/)
  end

  it "rejects successful output that is not marked as a compiled workflow" do
    allow(Dependabot::CommandHelpers).to receive(:capture3_with_timeout).with(array_including("compile")) do |args|
      File.write(File.join(args.last.fetch(:chdir), lockfile.name), "jobs: {}\n")
      ["", "", Dependabot::CommandHelpers::ProcessStatus.new(nil, 0)]
    end

    expect { compiler.compile(files: [markdown, lockfile], workflows: [markdown]) }
      .to raise_error(Dependabot::DependencyFileNotResolvable, /did not regenerate/)
  end
end
