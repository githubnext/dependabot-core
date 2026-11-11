# typed: strict
# frozen_string_literal: true

require "spec_helper"
require "dependabot/dependency_change_builder"
require "dependabot/github_actions"
require "dependabot/job"

RSpec.describe Dependabot::DependencyChangeBuilder do
  extend T::Sig

  sig { returns(Dependabot::DependencyChange) }
  subject(:dependency_change) do
    described_class.create_from(
      job: job,
      dependency_files: [markdown, lockfile],
      updated_dependencies: [dependency],
      change_source: dependency
    )
  end

  # rubocop:disable RSpec/ScatteredLet -- Keep Sorbet signatures immediately before their lets.
  sig { returns(Dependabot::DependencyFile) }
  let(:markdown) do
    Dependabot::DependencyFile.new(
      name: ".github/workflows/agentic.md",
      content: "---\npre-agent-steps:\n  - uses: actions/setup-node@v4\n---\nWorkflow instructions\n"
    )
  end

  sig { returns(Dependabot::DependencyFile) }
  let(:lockfile) do
    Dependabot::DependencyFile.new(
      name: ".github/workflows/agentic.lock.yml",
      content: "# gh-aw-metadata: {\"schema_version\":\"v4\"}\njobs: {}\n",
      support_file: true
    )
  end

  sig { returns(T::Hash[Symbol, Object]) }
  let(:previous_requirement) do
    {
      requirement: nil, groups: [], file: markdown.name,
      source: { type: "git", url: "https://github.com/actions/setup-node", ref: "v4", branch: nil },
      metadata: { declaration_string: "actions/setup-node@v4" }
    }
  end

  sig { returns(Dependabot::Dependency) }
  let(:dependency) do
    Dependabot::Dependency.new(
      name: "actions/setup-node",
      version: "5",
      previous_version: "4",
      package_manager: "github_actions",
      previous_requirements: [previous_requirement],
      requirements: [
        previous_requirement.merge(
          source: { type: "git", url: "https://github.com/actions/setup-node", ref: "v5", branch: nil }
        )
      ]
    )
  end

  sig { returns(Dependabot::Source) }
  let(:source) { Dependabot::Source.new(provider: "github", repo: "gocardless/bump", directory: "/") }

  sig { returns(Dependabot::Job) }
  let(:job) do
    instance_double(
      Dependabot::Job,
      package_manager: "github_actions",
      repo_contents_path: nil,
      credentials: [],
      experiments: {},
      security_updates_only?: false,
      cooldown: nil,
      blocked_versions: [],
      reject_external_code?: false,
      source: source
    )
  end
  # rubocop:enable RSpec/ScatteredLet

  before do
    allow(Dependabot::CommandHelpers).to receive(:capture3_with_timeout).and_call_original
    allow(Dependabot::CommandHelpers).to receive(:capture3_with_timeout).with(array_including("compile")) do |args|
      root = args.last.fetch(:chdir)
      File.write(File.join(root, lockfile.name), "#{lockfile.content}# Recompiled from updated Markdown\n")
      FileUtils.mkdir_p(File.join(root, ".github/aw"))
      File.write(File.join(root, ".github/aw/actions-lock.json"), "{\"entries\":{}}\n")
      ["", "", Dependabot::CommandHelpers::ProcessStatus.new(nil, 0)]
    end
  end

  it "includes the gh aw source and compiled workflow in the PR change" do
    expect(dependency_change.updated_dependency_files.map(&:name)).to contain_exactly(
      markdown.name, lockfile.name, ".github/aw/actions-lock.json"
    )
    expect(dependency_change.updated_dependency_files.find { |file| file.name == markdown.name }&.content)
      .to include("setup-node@v5")
    expect(dependency_change.updated_dependency_files.find { |file| file.name == lockfile.name }&.content)
      .to include("Recompiled from updated Markdown")
    expect(
      dependency_change.updated_dependency_files.find do |file|
        file.name == ".github/aw/actions-lock.json"
      end&.content
    )
      .to eq("{\"entries\":{}}\n")
    expect(Dependabot::CommandHelpers).to have_received(:capture3_with_timeout)
      .with(array_including("compile", "--schedule-seed", "gocardless/bump"))
  end
end
