# typed: strict
# frozen_string_literal: true

require "spec_helper"
require "digest"
require "dependabot/github_actions/file_updater/agentic_workflow_compiler/release"

RSpec.describe Dependabot::GithubActions::FileUpdater::AgenticWorkflowCompiler::Release do
  extend T::Sig

  sig { returns(Dependabot::GithubActions::FileUpdater::AgenticWorkflowCompiler::Release) } # rubocop:disable RSpec/DescribedClass -- Concrete Sorbet type.
  subject(:release) { described_class.new(credentials: []) }

  sig { params(tag: String, age: Integer, prerelease: T::Boolean, draft: T::Boolean).returns(T::Hash[String, Object]) }
  def release_data(tag, age:, prerelease: false, draft: false)
    {
      "tag_name" => tag, "published_at" => (Time.now - age).iso8601,
      "prerelease" => prerelease, "draft" => draft
    }
  end

  sig { params(data: T::Array[T::Hash[String, Object]]).void }
  def stub_releases(data)
    stub_request(:get, "https://api.github.com/repos/github/gh-aw/releases?per_page=100&page=1")
      .to_return(headers: { "content-type" => "application/json" }, body: data.to_json)
  end

  before { allow(Time).to receive(:now).and_return(Time.utc(2026, 11, 9, 16)) }

  it "selects the latest stable version outside the three-day cooldown" do
    stub_releases(
      [
        release_data("v1.2.0", age: 259_199),
        release_data("v1.1.0", age: 259_200),
        release_data("v1.0.0", age: 259_201)
      ]
    )
    expect(release.version).to eq("v1.1.0")
  end

  it "ignores prereleases, drafts and missing publication dates" do
    stub_releases(
      [
        release_data("v4.0.0", age: 400_000, draft: true),
        release_data("v3.0.0", age: 400_000, prerelease: true),
        { "tag_name" => "v2.0.0", "prerelease" => false },
        release_data("v1.0.0", age: 400_000)
      ]
    )
    expect(release.version).to eq("v1.0.0")
  end

  it "compares versions numerically rather than relying on publication order" do
    stub_releases([release_data("v1.9.0", age: 400_000), release_data("v1.10.0", age: 400_000)])
    expect(release.version).to eq("v1.10.0")
  end

  it "fails explicitly when no release is old enough" do
    stub_releases([release_data("v1.0.0", age: 259_199)])
    expect { release.version }.to raise_error(Dependabot::DependencyFileNotResolvable, /three-day cooldown/)
  end

  it "fails explicitly when the release list is empty" do
    stub_releases([])
    expect { release.version }.to raise_error(Dependabot::DependencyFileNotResolvable, /three-day cooldown/)
  end

  it "excludes malformed publication dates and prerelease version names" do
    stub_releases(
      [
        release_data("v2.0.0", age: 400_000).merge("published_at" => "invalid"),
        release_data("v2.0.0-rc.1", age: 400_000),
        release_data("v1.0.0", age: 400_000)
      ]
    )
    expect(release.version).to eq("v1.0.0")
  end

  it "searches subsequent pages when recent releases are all prereleases" do
    stub_releases(Array.new(100) { release_data("v2.0.0", age: 400_000, prerelease: true) })
    stub_request(:get, "https://api.github.com/repos/github/gh-aw/releases?per_page=100&page=2")
      .to_return(
        headers: { "content-type" => "application/json" },
        body: [release_data("v1.0.0", age: 400_000)].to_json
      )
    expect(release.version).to eq("v1.0.0")
  end

  describe "#download" do
    before do
      stub_const("RUBY_PLATFORM", "x86_64-linux")
      stub_releases([release_data("v1.0.0", age: 400_000)])
      stub_request(:get, "https://github.com/github/gh-aw/releases/download/v1.0.0/checksums.txt")
        .to_return(body: "#{Digest::SHA256.hexdigest('compiler')}  linux-amd64\n")
      stub_request(:get, "https://github.com/github/gh-aw/releases/download/v1.0.0/linux-amd64")
        .to_return(body: "compiler")
    end

    it "verifies the release checksum before making the compiler executable" do
      Dependabot::SharedHelpers.in_a_temporary_directory do |directory|
        path = release.download(directory.to_s)
        expect(File.binread(path)).to eq("compiler")
        expect(File.executable?(path)).to be(true)
      end
    end

    it "rejects a checksum mismatch" do
      stub_request(:get, "https://github.com/github/gh-aw/releases/download/v1.0.0/linux-amd64")
        .to_return(body: "tampered")
      Dependabot::SharedHelpers.in_a_temporary_directory do |directory|
        expect { release.download(directory.to_s) }
          .to raise_error(Dependabot::DependencyFileNotResolvable, /checksum verification failed/)
      end
    end

    it "rejects a missing checksum" do
      stub_request(:get, "https://github.com/github/gh-aw/releases/download/v1.0.0/checksums.txt")
        .to_return(body: "")
      Dependabot::SharedHelpers.in_a_temporary_directory do |directory|
        expect { release.download(directory.to_s) }
          .to raise_error(Dependabot::DependencyFileNotResolvable, /no checksum/)
      end
    end

    it "follows GitHub release asset redirects before checking the HTTP status" do
      stub_request(:get, "https://github.com/github/gh-aw/releases/download/v1.0.0/checksums.txt")
        .to_return(status: 302, headers: { "Location" => "https://release-assets.githubusercontent.com/checksums" })
      stub_request(:get, "https://release-assets.githubusercontent.com/checksums")
        .to_return(body: "#{Digest::SHA256.hexdigest('compiler')}  linux-amd64\n")
      Dependabot::SharedHelpers.in_a_temporary_directory do |directory|
        expect(File.binread(release.download(directory.to_s))).to eq("compiler")
      end
    end

    it "surfaces missing checksum assets rather than executing an unchecked binary" do
      stub_request(:get, "https://github.com/github/gh-aw/releases/download/v1.0.0/checksums.txt")
        .to_return(status: 404)
      Dependabot::SharedHelpers.in_a_temporary_directory do |directory|
        expect { release.download(directory.to_s) }
          .to raise_error(Dependabot::DependencyFileNotResolvable, /checksums.txt: HTTP 404/)
        expect(File.exist?(File.join(directory, ".gh-aw-compiler"))).to be(false)
      end
    end

    it "surfaces failed binary downloads" do
      stub_request(:get, "https://github.com/github/gh-aw/releases/download/v1.0.0/linux-amd64")
        .to_return(status: 503)
      Dependabot::SharedHelpers.in_a_temporary_directory do |directory|
        expect { release.download(directory.to_s) }
          .to raise_error(Dependabot::DependabotError, /linux-amd64: HTTP 503/)
      end
    end

    context "when running on ARM64 Linux" do
      before do
        stub_const("RUBY_PLATFORM", "aarch64-linux")
        stub_request(:get, "https://github.com/github/gh-aw/releases/download/v1.0.0/checksums.txt")
          .to_return(body: "#{Digest::SHA256.hexdigest('arm64-compiler')}  linux-arm64\n")
        stub_request(:get, "https://github.com/github/gh-aw/releases/download/v1.0.0/linux-arm64")
          .to_return(body: "arm64-compiler")
      end

      it "selects and verifies the ARM64 release binary" do
        Dependabot::SharedHelpers.in_a_temporary_directory do |directory|
          expect(File.binread(release.download(directory.to_s))).to eq("arm64-compiler")
        end
      end
    end

    context "when running on an unsupported platform" do
      before { stub_const("RUBY_PLATFORM", "unsupported-platform") }

      it "reports the platform without downloading or running a compiler" do
        Dependabot::SharedHelpers.in_a_temporary_directory do |directory|
          expect { release.download(directory.to_s) }
            .to raise_error(Dependabot::DependencyFileNotResolvable, /Unsupported gh aw compiler platform/)
        end
      end
    end
  end
end
