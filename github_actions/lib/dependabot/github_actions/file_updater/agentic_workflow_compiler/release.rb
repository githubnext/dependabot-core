# typed: strict
# frozen_string_literal: true

require "digest"
require "rubygems/version"

require "dependabot/github_actions/file_updater/agentic_workflow_compiler"
require "dependabot/clients/github_release"
require "dependabot/clients/github_with_retries"
require "dependabot/logger"
require "dependabot/registry_client"

module Dependabot
  module GithubActions
    class FileUpdater < Dependabot::FileUpdaters::Base
      class AgenticWorkflowCompiler
        class Release
          extend T::Sig

          REPOSITORY = "github/gh-aw"
          COOLDOWN_SECONDS = T.let(3 * 24 * 60 * 60, Integer)

          sig { params(credentials: T::Array[Dependabot::Credential]).void }
          def initialize(credentials:)
            @client = T.let(
              Clients::GithubWithRetries.for_github_dot_com(credentials: credentials),
              Clients::GithubWithRetries
            )
          end

          sig { returns(String) }
          def version
            cutoff = Time.now - COOLDOWN_SECONDS
            eligible = releases.filter_map do |resource|
              next if resource[:draft] == true

              release = Clients::GithubRelease.from_resource(resource)
              next unless release && !release.prerelease && release.tag_name.match?(/\Av\d+\.\d+\.\d+\z/)
              next unless release.published_at && T.must(release.published_at) <= cutoff

              release.tag_name
            end
            latest = eligible.max_by { |tag| Gem::Version.new(tag.delete_prefix("v")) }
            return latest if latest

            raise DependencyFileNotResolvable, "No stable gh aw release has completed the three-day cooldown"
          end

          sig { params(directory: String).returns(String) }
          def download(directory)
            tag = version
            asset = binary_asset
            checksums = download_asset(tag, "checksums.txt")
            checksum = checksums.lines.filter_map do |line|
              digest, name = line.split
              digest if name == asset && digest&.match?(/\A[0-9a-f]{64}\z/)
            end.first
            raise DependencyFileNotResolvable, "gh aw #{tag} has no checksum for #{asset}" unless checksum

            binary = download_asset(tag, asset)
            unless Digest::SHA256.hexdigest(binary) == checksum
              raise DependencyFileNotResolvable, "gh aw #{tag} checksum verification failed for #{asset}"
            end

            path = File.join(directory, ".gh-aw-compiler")
            File.binwrite(path, binary)
            File.chmod(0o755, path)
            Dependabot.logger.info("Compiling gh aw workflows with #{tag} (three-day release cooldown)")
            path
          end

          private

          sig { returns(T::Array[Sawyer::Resource]) }
          def releases
            results = T.let([], T::Array[Sawyer::Resource])
            page = 1
            loop do
              batch = @client.releases(REPOSITORY, per_page: 100, page: page)
              results.concat(batch)
              break if batch.length < 100

              page += 1
            end
            results
          end

          sig { returns(String) }
          def binary_asset
            case RUBY_PLATFORM
            when /aarch64-linux/ then "linux-arm64"
            when /x86_64-linux/ then "linux-amd64"
            else raise DependencyFileNotResolvable, "Unsupported gh aw compiler platform: #{RUBY_PLATFORM}"
            end
          end

          sig { params(tag: String, asset: String).returns(String) }
          def download_asset(tag, asset)
            response = RegistryClient.get(
              url: "https://github.com/#{REPOSITORY}/releases/download/#{tag}/#{asset}",
              options: { read_timeout: 120 }
            )
            unless response.status == 200
              raise DependencyFileNotResolvable, "Could not download gh aw #{tag}/#{asset}: HTTP #{response.status}"
            end

            response.body
          end
        end
      end
    end
  end
end
