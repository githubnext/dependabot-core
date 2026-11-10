# typed: strict
# frozen_string_literal: true

require "spec_helper"
require "base64"

require "dependabot/github_actions/agentic_workflow"
require "dependabot/github_actions/file_fetcher"
require "dependabot/github_actions/file_parser"
require "dependabot/github_actions/file_updater"

RSpec.describe Dependabot::GithubActions::AgenticWorkflow do
  extend T::Sig

  sig { params(name: String, content: String, directory: String).returns(Dependabot::DependencyFile) }
  def workflow_file(name, content, directory: "/")
    Dependabot::DependencyFile.new(name: name, content: content, directory: directory)
  end

  # rubocop:disable RSpec/ScatteredLet -- Keep Sorbet signatures immediately before their lets.
  sig { returns(Dependabot::DependencyFile) }
  let(:markdown) do
    workflow_file(".github/workflows/agentic.md", fixture("workflow_files", "agentic.md"))
  end

  sig { returns(Dependabot::DependencyFile) }
  let(:lockfile) do
    workflow_file(".github/workflows/agentic.lock.yml", fixture("workflow_files", "agentic.lock.yml"))
  end

  sig { returns(Dependabot::Source) }
  let(:source) { Dependabot::Source.new(provider: "github", repo: "gocardless/bump", directory: "/") }

  sig { returns(Dependabot::Dependency) }
  let(:dependency) do
    old_requirement = {
      requirement: nil, groups: [], file: markdown.name,
      source: { type: "git", url: "https://github.com/actions/setup-node", ref: "v4", branch: nil },
      metadata: { declaration_string: "actions/setup-node@v4" }
    }
    new_requirement = old_requirement.merge(
      source: { type: "git", url: "https://github.com/actions/setup-node", ref: "v5", branch: nil }
    )
    Dependabot::Dependency.new(
      name: "actions/setup-node",
      version: "5",
      previous_version: "4",
      package_manager: "github_actions",
      requirements: [new_requirement],
      previous_requirements: [old_requirement]
    )
  end
  # rubocop:enable RSpec/ScatteredLet

  describe "fetching" do
    sig { params(path: String, content: String).void }
    def stub_file(path, content)
      stub_request(:get, "https://api.github.com/repos/gocardless/bump/contents/#{path}?ref=sha")
        .to_return(
          headers: { "content-type" => "application/json" },
          body: { type: "file", name: File.basename(path), path: path, encoding: "base64",
                  content: Base64.strict_encode64(content) }.to_json
        )
    end

    before do
      stub_request(:get, "https://api.github.com/repos/gocardless/bump/contents/?ref=sha")
        .to_return(status: 200, headers: { "content-type" => "application/json" }, body: "[]")
      stub_request(:get, "https://api.github.com/repos/gocardless/bump/contents/.github/workflows?ref=sha")
        .to_return(
          headers: { "content-type" => "application/json" },
          body: [{ type: "file", name: "agentic.lock.yml", path: ".github/workflows/agentic.lock.yml" },
                 { type: "file", name: "agentic.md", path: ".github/workflows/agentic.md" }].to_json
        )
      stub_request(:get, "https://api.github.com/repos/gocardless/bump/contents/.github/aw?ref=sha")
        .to_return(
          headers: { "content-type" => "application/json" },
          body: "[]"
        )
      stub_file(lockfile.name, T.must(lockfile.content))
      stub_file(markdown.name, T.must(markdown.content))
      %w(.github/workflows/aw.json .github/aw/actions-lock.json).each do |path|
        stub_request(:get, "https://api.github.com/repos/gocardless/bump/contents/#{path}?ref=sha")
          .to_return(status: 404)
      end
    end

    sig { returns(T::Array[Dependabot::DependencyFile]) }
    def fetch_files
      fetcher = Dependabot::GithubActions::FileFetcher.new(source: source, credentials: [])
      allow(fetcher).to receive(:commit).and_return("sha")
      fetcher.files
    end

    it "fetches Markdown and treats the generated workflow as a support file" do
      files = fetch_files
      expect(files.map(&:name)).to contain_exactly(markdown.name, lockfile.name)
      expect(files.find { |file| file.name == lockfile.name }&.support_file?).to be(true)
      expect(files.find { |file| file.name == markdown.name }&.support_file?).to be(false)
    end

    it "recognizes compiler metadata without relying on the generated-file notice" do
      stub_file(lockfile.name, "# gh-aw-metadata: {\"schema_version\":\"v4\"}\njobs: {}\n")

      expect(fetch_files.map(&:name)).to contain_exactly(markdown.name, lockfile.name)
    end

    it "recognizes the compiler manifest when metadata is missing" do
      stub_file(lockfile.name, "# gh-aw-manifest: {\"version\":1,\"actions\":[]}\njobs: {}\n")

      expect(fetch_files.map(&:name)).to contain_exactly(markdown.name, lockfile.name)
    end

    it "does not classify ordinary YAML files by their metadata comments alone" do
      file = workflow_file(".github/workflows/agentic.yml", T.must(lockfile.content))
      expect(described_class.generated?(file)).to be(false)
    end

    context "with an explicit workflow directory" do
      sig { returns(Dependabot::Source) }
      let(:source) do
        Dependabot::Source.new(provider: "github", repo: "gocardless/bump", directory: "/.github/workflows")
      end

      it "retains repository-relative paths" do
        expect(fetch_files.map(&:path)).to contain_exactly(markdown.path, lockfile.path)
      end
    end

    it "fails rather than editing generated YAML when the source is missing" do
      stub_request(:get, "https://api.github.com/repos/gocardless/bump/contents/#{markdown.name}?ref=sha")
        .to_return(status: 404)
      expect { fetch_files }.to raise_error(Dependabot::DependencyFileNotFound)
    end

    it "fetches local imports and compiler configuration" do
      stub_request(:get, "https://api.github.com/repos/gocardless/bump/contents/.github/workflows?ref=sha")
        .to_return(
          headers: { "content-type" => "application/json" },
          body: [{ type: "file", name: "agentic.lock.yml", path: lockfile.name },
                 { type: "file", name: "aw.json", path: ".github/workflows/aw.json" }].to_json
        )
      stub_request(:get, "https://api.github.com/repos/gocardless/bump/contents/.github/aw?ref=sha")
        .to_return(
          headers: { "content-type" => "application/json" },
          body: [{ type: "file", name: "actions-lock.json", path: ".github/aw/actions-lock.json" }].to_json
        )
      stub_file(markdown.name, T.must(markdown.content).sub("engine:", "imports:\n  - shared/setup.md\nengine:"))
      stub_file(".github/workflows/shared/setup.md", "---\nsteps:\n  - uses: actions/cache@v4\n---\n")
      stub_file(".github/workflows/aw.json", "{}\n")
      stub_file(".github/aw/actions-lock.json", "{\"entries\":{}}\n")

      expect(fetch_files.map(&:name)).to contain_exactly(
        markdown.name,
        lockfile.name,
        ".github/workflows/shared/setup.md",
        ".github/workflows/aw.json",
        ".github/aw/actions-lock.json"
      )
    end

    it "fetches runtime prompts without parsing their frontmatter as dependencies" do
      stub_file(markdown.name, T.must(markdown.content) + "\n{{#runtime-import shared/prompt.md}}\n")
      stub_file(".github/shared/prompt.md", "---\nThis is a prompt, not YAML frontmatter\n")

      prompt = fetch_files.find { |file| file.name == ".github/shared/prompt.md" }
      expect(prompt&.support_file?).to be(true)
    end

    it "fetches a runtime import's file without its line range" do
      stub_file(markdown.name, T.must(markdown.content) + "\n{{#runtime-import shared/prompt.md:2-4}}\n")
      stub_file(".github/shared/prompt.md", "First line\nSecond line\n")

      expect(fetch_files.map(&:name)).to contain_exactly(
        markdown.name, lockfile.name, ".github/shared/prompt.md"
      )
    end

    it "skips missing optional frontmatter imports" do
      stub_file(markdown.name, T.must(markdown.content).sub("engine:", "imports:\n  - optional.md?\nengine:"))

      expect(fetch_files.map(&:name)).to contain_exactly(markdown.name, lockfile.name)
    end

    it "fetches section imports using the source file path" do
      stub_file(markdown.name, T.must(markdown.content).sub("engine:", "imports:\n  - shared/setup.md#Setup\nengine:"))
      stub_file(".github/workflows/shared/setup.md", "---\npre-agent-steps:\n  - uses: actions/cache@v4\n---\n")

      expect(fetch_files.map(&:name)).to contain_exactly(
        markdown.name, lockfile.name, ".github/workflows/shared/setup.md"
      )
    end

    it "deduplicates cyclic local imports" do
      stub_file(markdown.name, T.must(markdown.content).sub("engine:", "imports:\n  - shared/setup.md\nengine:"))
      stub_file(".github/workflows/shared/setup.md", "---\nimports:\n  - ../agentic.md\n---\n")
      expect(fetch_files.map(&:name)).to contain_exactly(
        markdown.name, lockfile.name, ".github/workflows/shared/setup.md"
      )
    end

    it "does not fetch reserved Git metadata as an import" do
      stub_file(markdown.name, T.must(markdown.content).sub("engine:", "imports:\n  - ../../.git/config\nengine:"))
      expect { fetch_files }.to raise_error(Dependabot::DependencyFileNotResolvable, /reserved Git metadata/)
    end
  end

  describe "parsing" do
    before do
      stub_request(:get, "https://github.com/actions/setup-node.git/info/refs?service=git-upload-pack")
        .to_return(status: 404)
    end

    it "parses authored actions, not generated actions or Markdown examples" do
      parser = Dependabot::GithubActions::FileParser.new(dependency_files: [markdown, lockfile], source: source)
      dependencies = parser.parse

      expect(dependencies.map(&:name)).to eq(["actions/setup-node"])
      expect(T.must(dependencies.first).requirements.map(&:file)).to eq([markdown.name])
    end

    it "reports malformed frontmatter using the Markdown path" do
      invalid = workflow_file(markdown.name, "---\nsteps: [\n---\nInstructions\n")
      parser = Dependabot::GithubActions::FileParser.new(dependency_files: [invalid, lockfile], source: source)
      expect { parser.parse }.to raise_error(Dependabot::DependencyFileNotParseable, /agentic.md/)
    end

    it "parses both agent steps and custom jobs" do
      stub_request(:get, "https://github.com/actions/checkout.git/info/refs?service=git-upload-pack")
        .to_return(status: 404)
      content = T.must(markdown.content).sub(
        "pre-agent-steps:",
        "jobs:\n  custom:\n    steps:\n      - uses: actions/checkout@v4\npre-agent-steps:"
      )
      authored = workflow_file(markdown.name, content)
      parser = Dependabot::GithubActions::FileParser.new(dependency_files: [authored, lockfile], source: source)
      expect(parser.parse.map(&:name)).to contain_exactly("actions/checkout", "actions/setup-node")
    end

    it "parses actions in custom safe-output jobs" do
      authored = workflow_file(
        markdown.name,
        "---\nsafe-outputs:\n  jobs:\n    notify:\n      steps:\n        - uses: actions/setup-node@v4\n---\n"
      )
      parser = Dependabot::GithubActions::FileParser.new(dependency_files: [authored, lockfile], source: source)
      expect(parser.parse.map(&:name)).to eq(["actions/setup-node"])
    end

    it "parses pre-agent and post steps with source metadata for flow sequences" do
      stub_request(:get, "https://github.com/actions/checkout.git/info/refs?service=git-upload-pack")
        .to_return(status: 404)
      authored = workflow_file(
        markdown.name,
        "---\npre-agent-steps: [{ uses: actions/setup-node@v4 }]\n" \
        "post-steps:\n  - uses: actions/checkout@v4\n---\nWorkflow instructions\n"
      )
      parser = Dependabot::GithubActions::FileParser.new(dependency_files: [authored, lockfile], source: source)
      dependencies = parser.parse
      expect(dependencies.map(&:name)).to contain_exactly("actions/setup-node", "actions/checkout")
      requirement = T.must(dependencies.find { |dep| dep.name == "actions/setup-node" }).requirements.first
      expect(T.must(requirement).metadata).to include(
        yaml_source: include(path: ["pre-agent-steps", 0, "uses"])
      )
    end
  end

  describe "updating" do
    sig { returns(Dependabot::GithubActions::FileUpdater) }
    let(:updater) do
      Dependabot::GithubActions::FileUpdater.new(
        dependency_files: [markdown, lockfile],
        dependencies: [dependency],
        credentials: [],
        options: { source_repo: "gocardless/bump" }
      )
    end

    it "updates only frontmatter and returns the compiler's lockfile" do
      compiler = instance_double(Dependabot::GithubActions::FileUpdater::AgenticWorkflowCompiler)
      compiled = lockfile.dup
      compiled.content = fixture("workflow_files", "agentic_updated.lock.yml")
      allow(compiler).to receive(:compile).and_return([compiled])
      allow(Dependabot::GithubActions::FileUpdater::AgenticWorkflowCompiler).to receive(:new).and_return(compiler)

      files = updater.updated_dependency_files
      updated_markdown = T.must(files.find { |file| file.name == markdown.name })
      expect(updated_markdown.content).to include("uses: actions/setup-node@v5")
      expect(updated_markdown.content).to end_with("  - uses: actions/setup-node@v4\n```\n")
      expect(files.find { |file| file.name == lockfile.name }&.content).to eq(compiled.content)
      expect(compiler).to have_received(:compile).with(
        files: array_including(have_attributes(name: markdown.name, content: updated_markdown.content)),
        workflows: [markdown]
      )
    end

    it "keeps compiler fixes in the source without returning duplicate Markdown files" do
      compiled = lockfile.dup
      compiled.content = fixture("workflow_files", "agentic_updated.lock.yml")
      migrated = markdown.dup
      migrated.content = T.must(markdown.content)
                          .sub("setup-node@v4", "setup-node@v5")
                          .sub('node-version: "22"', 'node-version: "24"')
      compiler_class = Dependabot::GithubActions::FileUpdater::AgenticWorkflowCompiler
      compiler = instance_double(compiler_class, compile: [compiled, migrated])
      allow(compiler_class).to receive(:new).and_return(compiler)

      files = updater.updated_dependency_files

      expect(files.map(&:name)).to contain_exactly(markdown.name, lockfile.name)
      expect(files.find { |file| file.name == markdown.name }&.content).to eq(migrated.content)
    end

    context "with a UTF-8 prompt and CRLF line endings" do
      sig { returns(Dependabot::DependencyFile) }
      let(:markdown) do
        content = fixture("workflow_files", "agentic.md").sub("# Agentic workflow", "# Caf\u00e9 workflow")
        workflow_file(".github/workflows/agentic.md", "\uFEFF#{content.gsub("\n", "\r\n")}")
      end

      it "preserves every byte outside the selected action reference" do
        compiler_class = Dependabot::GithubActions::FileUpdater::AgenticWorkflowCompiler
        compiler = instance_double(compiler_class, compile: [])
        allow(compiler_class).to receive(:new).and_return(compiler)
        original_content = T.must(markdown.content).dup
        files = updater.updated_dependency_files

        expect(T.must(files.first).content).to eq(original_content.sub("setup-node@v4", "setup-node@v5"))
        expect(markdown.content).to eq(original_content)
      end
    end

    it "refuses a generated-only dependency update" do
      requirements = dependency.requirements.map { |req| req.to_h.merge(file: lockfile.name) }
      previous = T.must(dependency.previous_requirements).map { |req| req.to_h.merge(file: lockfile.name) }
      generated_dependency = Dependabot::Dependency.new(
        name: dependency.name,
        version: "5",
        previous_version: "4",
        package_manager: "github_actions",
        requirements: requirements,
        previous_requirements: previous
      )
      generated_updater = Dependabot::GithubActions::FileUpdater.new(
        dependency_files: [lockfile], dependencies: [generated_dependency], credentials: []
      )

      expect { generated_updater.updated_dependency_files }
        .to raise_error(Dependabot::DependencyFileNotResolvable, /Markdown/)
    end

    sig { params(imported: Dependabot::DependencyFile).returns(Dependabot::Dependency) }
    def updated_import_dependency(imported)
      Dependabot::Dependency.new(
        name: dependency.name,
        version: "5",
        previous_version: "4",
        package_manager: "github_actions",
        requirements: dependency.requirements.map { |req| req.to_h.merge(file: imported.name) },
        previous_requirements: T.must(dependency.previous_requirements).map do |req|
          req.to_h.merge(file: imported.name)
        end
      )
    end

    sig { params(import_path: String).void }
    def expect_imported_workflow_update(import_path)
      imported = workflow_file(".github/workflows/shared/setup.md", T.must(markdown.content))
      root = workflow_file(markdown.name, "---\nimports:\n  - #{import_path}\n---\nWorkflow instructions\n")
      compiler_class = Dependabot::GithubActions::FileUpdater::AgenticWorkflowCompiler
      compiler = instance_double(compiler_class, compile: [])
      allow(compiler_class).to receive(:new).and_return(compiler)
      imported_updater = Dependabot::GithubActions::FileUpdater.new(
        dependency_files: [root, imported, lockfile],
        dependencies: [updated_import_dependency(imported)],
        credentials: []
      )

      files = imported_updater.updated_dependency_files
      expect(T.must(files.first).content).to include("setup-node@v5")
      expect(compiler).to have_received(:compile).with(files: anything, workflows: [root])
    end

    it "recompiles workflows that consume an updated relative import" do
      expect_imported_workflow_update("shared/setup.md")
    end

    it "recompiles workflows that consume an updated repository-relative import" do
      expect_imported_workflow_update(".github/workflows/shared/setup.md")
    end

    it "recompiles workflows that consume an updated absolute repository import" do
      expect_imported_workflow_update("/.github/workflows/shared/setup.md")
    end

    it "does not recompile workflows that only import an updated file as a runtime prompt" do
      unrelated = workflow_file(
        ".github/workflows/unrelated.md",
        "---\non: workflow_dispatch\n---\n{{#runtime-import .github/workflows/agentic.md}}\n"
      )
      unrelated_lockfile = workflow_file(".github/workflows/unrelated.lock.yml", T.must(lockfile.content))
      compiler_class = Dependabot::GithubActions::FileUpdater::AgenticWorkflowCompiler
      compiler = instance_double(compiler_class, compile: [])
      allow(compiler_class).to receive(:new).and_return(compiler)
      prompt_updater = Dependabot::GithubActions::FileUpdater.new(
        dependency_files: [markdown, lockfile, unrelated, unrelated_lockfile],
        dependencies: [dependency],
        credentials: []
      )

      prompt_updater.updated_dependency_files

      expect(compiler).to have_received(:compile).with(files: anything, workflows: [markdown])
    end

    it "does not parse the frontmatter of unrelated runtime prompts" do
      unrelated = workflow_file(
        ".github/workflows/unrelated.md",
        "---\non: workflow_dispatch\n---\n{{#runtime-import .github/shared/prompt.md}}\n"
      )
      unrelated_lockfile = workflow_file(".github/workflows/unrelated.lock.yml", T.must(lockfile.content))
      prompt = workflow_file(".github/shared/prompt.md", "---\nPlain prompt text, not frontmatter\n")
      prompt.support_file = true
      compiler_class = Dependabot::GithubActions::FileUpdater::AgenticWorkflowCompiler
      compiler = instance_double(compiler_class, compile: [])
      allow(compiler_class).to receive(:new).and_return(compiler)
      prompt_updater = Dependabot::GithubActions::FileUpdater.new(
        dependency_files: [markdown, lockfile, unrelated, unrelated_lockfile, prompt],
        dependencies: [dependency],
        credentials: []
      )

      expect { prompt_updater.updated_dependency_files }.not_to raise_error
      expect(compiler).to have_received(:compile).with(files: anything, workflows: [markdown])
    end
  end
end
