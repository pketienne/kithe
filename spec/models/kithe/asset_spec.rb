require 'rails_helper'
require 'digest'


RSpec.describe Kithe::Asset, type: :model do
  let(:asset) { FactoryBot.create(:kithe_asset) }
  let(:asset2) { FactoryBot.create(:kithe_asset) }


  it "can create with title" do
    work = Kithe::Asset.create(title: "some title")
    expect(work).to be_present
    expect(work.title).to eq "some title"
  end

  it "requires a title" do
    expect {
      work = Kithe::Asset.create!
    }.to raise_error(ActiveRecord::RecordInvalid)
  end

  it "can not have any members" do
    asset.members << asset2
    expect {
      asset2.save!
    }.to raise_error(ActiveRecord::RecordInvalid)
  end

  # should we be testing the uploader directly instead/in addition?
  # We're doing it "integration" style here, but fixing queue adapter to inline
  # to make it straightforward. Maybe better way(s) to test, or not.
  # https://github.com/shrinerb/shrine/blob/master/doc/testing.md
  describe "file attachment", queue_adapter: :inline do
    let(:source_path) { Kithe::Engine.root.join("spec/test_support/images/1x1_pixel.jpg") }
    let(:source) { File.open(source_path) }
    let(:asset) { Kithe::Asset.new(title: "foo") }

    it "can attach file correctly" do
      asset.file = source

      asset.save!
      # since it happened in a job, after commit, we gotta reload, even though :inline queue for some reason
      asset.reload

      expect(asset.file).to be_present
      expect(asset.stored?).to be true
      expect(asset.content_type).to eq("image/jpeg")
      expect(asset.size).to eq(File.open(source_path).size)
      expect(asset.height).to eq(1)
      expect(asset.width).to eq(1)

      # This is the file location/storage path, currently under UUID pk.
      expect(asset.file.id).to match %r{\Aasset/#{asset.id}/.*\.jpg}

      # checksums
      expect(asset.sha1).to eq(Digest::SHA1.hexdigest(File.open(source_path).read))
      expect(asset.md5).to eq(Digest::MD5.hexdigest(File.open(source_path).read))
      expect(asset.sha512).to eq(Digest::SHA512.hexdigest(File.open(source_path).read))
    end

    describe "pdf file" do

      it "extracts page count" do

      end
    end
  end

  describe "direct uploads", queue_adapter: :inline do
    let(:sample_file_path) { Kithe::Engine.root.join("spec/test_support/images/1x1_pixel.jpg") }
    let(:cached_file) { asset.file_attacher.cache.upload(File.open(sample_file_path)) }
    it "can attach json hash" do
      asset.file = {
        id: cached_file.id,
        storage: cached_file.storage_key,
        metadata: {
          filename: "echidna.jpg"
        }
      }.to_json

      asset.save!
      asset.reload

      expect(asset.file).to be_present
      expect(asset.stored?).to be true
      expect(asset.content_type).to eq("image/jpeg")
      expect(asset.size).to eq(File.open(sample_file_path).size)
      expect(asset.height).to eq(1)
      expect(asset.width).to eq(1)

      # This is the file location/storage path, currently under UUID pk.
      expect(asset.file.id).to match %r{\Aasset/#{asset.id}/.*\.jpg}

      # checksums
      expect(asset.sha1).to eq(Digest::SHA1.hexdigest(File.open(sample_file_path).read))
      expect(asset.md5).to eq(Digest::MD5.hexdigest(File.open(sample_file_path).read))
      expect(asset.sha512).to eq(Digest::SHA512.hexdigest(File.open(sample_file_path).read))
    end
  end

  describe "remote urls", queue_adapter: :inline do
    it "can assign and promote" do
      stub_request(:any, "www.example.com/bar.html?foo=bar").
        to_return(body: "Example Response" )

      asset.file = {"id" => "http://www.example.com/bar.html?foo=bar", "storage" => "remote_url"}
      asset.save!
      asset.reload

      expect(asset.file.storage_key).to eq(asset.file_attacher.store.storage_key.to_s)
      expect(asset.stored?).to be true
      expect(asset.file.read).to include("Example Response")
      expect(asset.file.id).to end_with(".html") # no query params
    end

    it "will fetch headers" do
      stubbed = stub_request(:any, "www.example.com/bar.html?foo=bar").
                  to_return(body: "Example Response" )

      asset.file = {"id" => "http://www.example.com/bar.html?foo=bar",
                    "storage" => "remote_url",
                    "headers" => {"Authorization" => "Bearer TestToken"}}
      asset.save!

      expect(
        a_request(:get, "www.example.com/bar.html?foo=bar").with(
          headers: {'Authorization'=>'Bearer TestToken', 'User-Agent' => /.+/}
        )
      ).to have_been_made.times(1)
    end
  end
end
