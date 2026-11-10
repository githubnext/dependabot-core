# typed: strict
# frozen_string_literal: true

require "pathname"
require "sorbet-runtime"

require "dependabot/dependency_file"
require "dependabot/errors"
require "dependabot/github_actions/workflow_file"

module Dependabot
  module GithubActions
    class AgenticWorkflow
      extend T::Sig

      ACTION_CACHE_PATH = ".github/aw/actions-lock.json"
      FRONTMATTER_PATTERN = /\A(?:\uFEFF)?---[ \t]*\r?\n(?<yaml>.*?)^---[ \t]*(?:\r?\n|\z)/m

      class Import < T::Struct
        const :path, String
        const :optional, T::Boolean, default: false
        const :frontmatter, T::Boolean, default: true
      end

      sig { params(file: Dependabot::DependencyFile).returns(T::Boolean) }
      def self.generated?(file)
        file.name.end_with?(".lock.yml") &&
          file.content.to_s.match?(/^# gh-aw-(?:metadata|manifest):/)
      end

      sig { params(file: Dependabot::DependencyFile).returns(String) }
      def self.source_path(file)
        file.path.delete_prefix("/").sub(/\.lock\.yml\z/, ".md")
      end

      sig { params(file: Dependabot::DependencyFile).void }
      def initialize(file)
        @file = file
        @content = T.let(T.must(file.content), String)
        @frontmatter_match = T.let(FRONTMATTER_PATTERN.match(@content), T.nilable(MatchData))
      end

      sig { returns(String) }
      def frontmatter
        return T.must(@frontmatter_match[:yaml]) if @frontmatter_match
        return "" unless @content.match?(/\A(?:\uFEFF)?---[ \t]*\r?\n/)

        raise DependencyFileNotParseable.new(@file.path, "Unterminated gh aw YAML frontmatter")
      end

      sig { returns(WorkflowFile) }
      def workflow_file
        WorkflowFile.new(frontmatter)
      end

      sig { params(yaml: String).returns(String) }
      def updated_content(yaml)
        match = T.must(@frontmatter_match)
        T.must(@content[0...match.begin(:yaml)]) + yaml + @content[match.end(:yaml)..].to_s
      end

      sig { params(workflow_directory: String, include_frontmatter: T::Boolean).returns(T::Array[Import]) }
      def imports(workflow_directory:, include_frontmatter: true)
        paths = include_frontmatter ? frontmatter_imports : []
        paths.map do |path|
          target = T.must(path.delete_suffix("?").split("#", 2).first)
          Import.new(path: resolve_import(target, workflow_directory), optional: path.end_with?("?"))
        end + body_imports(workflow_directory)
      rescue Psych::SyntaxError, Psych::DisallowedClass, Psych::BadAlias
        raise DependencyFileNotParseable, @file.path
      end

      private

      sig { returns(T::Array[String]) }
      def frontmatter_imports
        data = workflow_file.data
        return [] unless data.is_a?(Hash)

        imports = data["imports"]
        return [] unless imports.is_a?(Array)

        imports.filter_map do |entry|
          path = entry.is_a?(Hash) ? entry["uses"] || entry["path"] : entry
          path if path.is_a?(String) && local_import?(path)
        end
      end

      sig { params(workflow_directory: String).returns(T::Array[Import]) }
      def body_imports(workflow_directory)
        imports = T.let([], T::Array[Import])
        @content.scan(/\{\{#(?<kind>runtime-import\??|import)\s+(?<path>[^\s}]+)\s*\}\}/) do
          match = T.must(Regexp.last_match)
          path = T.must(match[:path])
          next unless local_import?(path)

          runtime = match[:kind] != "import"
          imports << Import.new(
            path: runtime ? resolve_runtime_import(path, workflow_directory) : resolve_import(path, workflow_directory),
            optional: match[:kind] == "runtime-import?",
            frontmatter: !runtime
          )
        end
        imports
      end

      sig { params(path: String).returns(T::Boolean) }
      def local_import?(path)
        !path.match?(%r{\Ahttps?://}) && !path.include?("@")
      end

      sig { params(path: String, workflow_directory: String).returns(String) }
      def resolve_runtime_import(path, workflow_directory)
        if path.start_with?("/")
          raise DependencyFileNotResolvable, "gh aw runtime imports cannot use absolute paths: #{path}"
        end

        target = path.sub(/:\d+(?:-\d+)?\z/, "")
        target = ".github/#{target}" unless target.start_with?(".github/", ".agents/")
        resolved = resolve_import(target, workflow_directory)
        unless resolved.start_with?(".github/", ".agents/")
          raise DependencyFileNotResolvable, "gh aw runtime import escapes its source directory: #{path}"
        end

        resolved
      end

      sig { params(path: String, workflow_directory: String).returns(String) }
      def resolve_import(path, workflow_directory)
        base = if path.start_with?("/", ".github/", ".agents/")
                 ""
               elsif path.start_with?("./", "../") || !path.include?("/")
                 File.dirname(@file.path.delete_prefix("/"))
               else
                 workflow_directory
               end
        resolved = Pathname.new(File.join(base, path.delete_prefix("/")).delete_prefix("/")).cleanpath.to_s
        if resolved == ".." || resolved.start_with?("../")
          raise DependencyFileNotResolvable, "gh aw import escapes the repository: #{path}"
        end
        if resolved.split("/").include?(".git")
          raise DependencyFileNotResolvable, "gh aw imports cannot read reserved Git metadata: #{path}"
        end

        resolved
      end
    end
  end
end
