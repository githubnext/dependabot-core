# typed: strong
# frozen_string_literal: true

require "fileutils"

require "dependabot/github_actions/file_updater"
require "dependabot/command_helpers"
require "dependabot/github_actions/agentic_workflow"
require "dependabot/github_actions/lockfile/env"
require "dependabot/shared_helpers"

module Dependabot
  module GithubActions
    class FileUpdater < Dependabot::FileUpdaters::Base
      class AgenticWorkflowCompiler
        extend T::Sig

        sig { params(credentials: T::Array[Dependabot::Credential], repository: T.nilable(String)).void }
        def initialize(credentials:, repository: nil)
          @credentials = credentials
          @repository = repository
        end

        sig do
          params(
            files: T::Array[Dependabot::DependencyFile],
            workflows: T::Array[Dependabot::DependencyFile]
          ).returns(T::Array[Dependabot::DependencyFile])
        end
        def compile(files:, workflows:)
          SharedHelpers.in_a_temporary_repo_directory do |directory|
            root = directory.to_s
            materialize(files, root)
            SharedHelpers.run_shell_command(["git", "init", "--quiet"], cwd: root)
            workflows.each { |workflow| compile_workflow(root, workflow) }
            compiled_files(root, files, workflows)
          end
        end

        private

        sig { params(files: T::Array[Dependabot::DependencyFile], root: String).void }
        def materialize(files, root)
          files.each do |file|
            path = File.join(root, file.path.delete_prefix("/"))
            FileUtils.mkdir_p(File.dirname(path))
            File.write(path, file.content)
          end
        end

        sig { params(root: String, workflow: Dependabot::DependencyFile).void }
        def compile_workflow(root, workflow)
          path = workflow.path.delete_prefix("/")
          arguments = [
            "gh", "aw", "compile", "--fix", "--no-check-update", "--dir", File.dirname(path), "--", File.basename(path)
          ]
          arguments.insert(3, "--schedule-seed", @repository) if @repository
          env = Lockfile::Env.build(@credentials).merge("GH_PROMPT_DISABLED" => "1")
          stdout, stderr, process = CommandHelpers.capture3_with_timeout([env, *arguments, { chdir: root }])
          return if process&.success?

          raise DependencyFileNotResolvable,
                "gh aw could not compile #{workflow.path} (#{process}): #{stderr}#{stdout}"
        end

        sig do
          params(
            root: String,
            files: T::Array[Dependabot::DependencyFile],
            workflows: T::Array[Dependabot::DependencyFile]
          ).returns(T::Array[Dependabot::DependencyFile])
        end
        def compiled_files(root, files, workflows)
          lockfiles = workflows.map { |workflow| compiled_lockfile(root, files, workflow) }
          markdown_files = updated_markdown_files(root, files)
          cache = updated_cache(root, files, T.must(workflows.first))
          lockfiles + markdown_files + [cache].compact
        end

        sig do
          params(root: String, files: T::Array[Dependabot::DependencyFile])
            .returns(T::Array[Dependabot::DependencyFile])
        end
        def updated_markdown_files(root, files)
          files.filter_map do |file|
            next unless file.name.end_with?(".md") && !file.support_file?

            path = File.join(root, file.path.delete_prefix("/"))
            raise DependencyFileNotResolvable, "gh aw removed #{file.path}" unless File.file?(path)

            content = File.read(path)
            next if content == file.content

            updated_file = file.dup
            updated_file.content = content
            updated_file
          end
        end

        sig do
          params(
            root: String,
            files: T::Array[Dependabot::DependencyFile],
            workflow: Dependabot::DependencyFile
          ).returns(Dependabot::DependencyFile)
        end
        def compiled_lockfile(root, files, workflow)
          path = workflow.path.delete_prefix("/").sub(/\.md\z/, ".lock.yml")
          lockfile = files.find { |file| file.path.delete_prefix("/") == path }
          raise DependencyFileNotFound, path unless lockfile
          raise DependencyFileNotResolvable, "gh aw did not produce #{path}" unless File.file?(File.join(root, path))

          updated_file = lockfile.dup
          updated_file.content = File.read(File.join(root, path))
          updated_file.support_file = false
          if updated_file.content == lockfile.content || !AgenticWorkflow.generated?(updated_file)
            raise DependencyFileNotResolvable, "gh aw did not regenerate #{path}"
          end

          updated_file
        end

        sig do
          params(
            root: String,
            files: T::Array[Dependabot::DependencyFile],
            workflow: Dependabot::DependencyFile
          ).returns(T.nilable(Dependabot::DependencyFile))
        end
        def updated_cache(root, files, workflow)
          cache = files.find { |file| file.path.delete_prefix("/") == AgenticWorkflow::ACTION_CACHE_PATH }
          cache_path = File.join(root, AgenticWorkflow::ACTION_CACHE_PATH)
          return unless File.file?(cache_path)

          content = File.read(cache_path)
          return if cache&.content == content

          updated_cache = cache&.dup || Dependabot::DependencyFile.new(
            name: Pathname.new("/#{AgenticWorkflow::ACTION_CACHE_PATH}")
                          .relative_path_from(Pathname.new(workflow.directory)).to_s,
            directory: workflow.directory,
            content: nil,
            support_file: false
          )
          updated_cache.content = content
          updated_cache.support_file = false
          updated_cache
        end
      end
    end
  end
end
