require 'rails_helper'

describe "Kithe::Asset promotion hooks", queue_adapter: :inline do
  temporary_class("TestAsset") do
    Class.new(Kithe::Asset) do
      define_derivative :test do
        # no-op, but we need a definition so will be scheduled
      end
    end
  end

  let(:unsaved_asset) {
    TestAsset.new(title: "test",
      file: File.open(Kithe::Engine.root.join("spec/test_support/images/1x1_pixel.jpg"))
    )
  }

  describe "before_promotion cancellation" do
    temporary_class("TestAsset") do
      Class.new(Kithe::Asset) do
        before_promotion do
          throw :abort
        end

        after_promotion do
          raise "Should not get here"
        end
      end
    end

    it "works" do
      expect_any_instance_of(Kithe::AssetUploader::Attacher).not_to receive(:store!)

      unsaved_asset.save!
      unsaved_asset.reload
      expect(unsaved_asset.stored?).to be(false)
    end

    describe "with promotion_directives[:skip_callbacks]" do
      it "doesn't cancel" do
        expect_any_instance_of(Kithe::AssetUploader::Attacher).to receive(:store!).and_call_original

        unsaved_asset.file_attacher.set_promotion_directives(skip_callbacks: true)
        unsaved_asset.save!
        unsaved_asset.reload

        expect(unsaved_asset.stored?).to be(true)
      end
    end
  end

  describe "after_promotion" do
    let(:after_promotion_receiver) { proc {} }

    temporary_class("TestAsset") do
      receiver = after_promotion_receiver
      Class.new(Kithe::Asset) do
        after_promotion do
          receiver.call
        end
      end
    end

    it "is called" do
      expect(after_promotion_receiver).to receive(:call)
      unsaved_asset.save!
    end

    describe "with promotion_directives[:skip_callbacks]" do
      it "doesn't call" do
        expect(after_promotion_receiver).not_to receive(:call)

        unsaved_asset.file_attacher.set_promotion_directives(skip_callbacks: true)
        unsaved_asset.save!
      end
    end
  end

  describe "around_promotion" do
    let(:before_receiver) { proc { expect(self.stored?).to be(false) }}
    let(:after_receiver) { proc { expect(self.stored?).to be(true) }}

    temporary_class("TestAsset") do
      Class.new(Kithe::Asset) do
        around_promotion :my_around_promotion

        def my_around_promotion
          yield
        end
      end
    end

    it "is called" do
      expect_any_instance_of(TestAsset).to receive(:my_around_promotion).once.and_call_original
      unsaved_asset.save!
      unsaved_asset.reload
      expect(unsaved_asset.stored?).to be(true)
    end
  end

  describe "promotion_directive :promote", queue_adapter: :test do
    it "can cancel promotion" do
      expect_any_instance_of(Kithe::AssetUploader::Attacher).not_to receive(:promote)

      unsaved_asset.file_attacher.set_promotion_directives(promote: false)

      unsaved_asset.save!
      unsaved_asset.reload

      expect(unsaved_asset.stored?).to be(false)

      expect(Kithe::AssetPromoteJob).not_to have_been_enqueued
      expect(Kithe::CreateDerivativesJob).not_to have_been_enqueued
    end

    it "can force promotion in foreground" do
      unsaved_asset.file_attacher.set_promotion_directives(promote: :inline)

      unsaved_asset.save!
      unsaved_asset.reload

      expect(unsaved_asset.stored?).to be(true)
      expect(Kithe::AssetPromoteJob).not_to have_been_enqueued
      expect(Kithe::CreateDerivativesJob).to have_been_enqueued
      expect(ActiveJob::Base.queue_adapter.performed_jobs.size).to eq(0)
    end

    it "raises on unrecgonized value" do
      unsaved_asset.file_attacher.set_promotion_directives(promote: :something)
      expect {
        unsaved_asset.save!
      }.to raise_error(ArgumentError)
    end

    describe ", create_derivatives: false" do
      it "does not create derivatives" do
        expect_any_instance_of(Kithe::Asset).not_to receive(:create_derivatives)

        unsaved_asset.file_attacher.set_promotion_directives(promote: :inline, create_derivatives: false)

        unsaved_asset.save!
        unsaved_asset.reload

        expect(Kithe::AssetPromoteJob).not_to have_been_enqueued
        expect(Kithe::CreateDerivativesJob).not_to have_been_enqueued
        expect(ActiveJob::Base.queue_adapter.performed_jobs.size).to eq(0)
      end
    end

    describe ", create_derivatives: :inline" do
      it "creates derivatives inline" do
        expect_any_instance_of(Kithe::Asset).to receive(:create_derivatives)

        unsaved_asset.file_attacher.set_promotion_directives(promote: :inline, create_derivatives: :inline)

        unsaved_asset.save!
        unsaved_asset.reload

        expect(Kithe::AssetPromoteJob).not_to have_been_enqueued
        expect(Kithe::CreateDerivativesJob).not_to have_been_enqueued
        expect(ActiveJob::Base.queue_adapter.performed_jobs.size).to eq(0)
      end
    end
  end

  describe "promotion_directive :delete", queue_adapter: :test do
    let(:saved_asset) do
      TestAsset.new(title: "test",
        file: File.open(Kithe::Engine.root.join("spec/test_support/images/1x1_pixel.jpg"))
      ).tap do |asset|
        asset.set_promotion_directives(promote: "inline")
        asset.save!
        asset.reload
        expect(asset.stored?).to be(true)
      end
    end

    let!(:existing_file) {  saved_asset.file }

    it "can cancel deletion" do
      expect(Kithe::AssetUploader::Attacher).not_to receive(:delete)


      saved_asset.set_promotion_directives(delete: false)
      saved_asset.destroy!

      expect(Kithe::AssetDeleteJob).not_to have_been_enqueued
      expect(existing_file.exists?).to be(true)
    end

    it "can force deletion in foreground" do
      saved_asset.set_promotion_directives(delete: :inline)
      saved_asset.destroy!

      expect(existing_file.exists?).to be(false)
      expect(Kithe::AssetDeleteJob).not_to have_been_enqueued
      expect(ActiveJob::Base.queue_adapter.performed_jobs.size).to eq(0)
    end
  end

  describe "unrecognized promotion directive" do
    it "raises" do
      expect {
        unsaved_asset.file_attacher.set_promotion_directives(:bad_made_up => true)
      }.to raise_error(ArgumentError)
    end
  end

  describe "delegated from asset" do
    around do |example|
      original_class_settings = Kithe::Asset.promotion_directives
      example.run
      Kithe::Asset.promotion_directives = original_class_settings
    end

    it "can set from class attribute" do
      Kithe::Asset.promotion_directives = { promote: :inline }
      asset = Kithe::Asset.new
      expect(asset.file_attacher.promotion_directives).to eq(promote: :inline)
    end

    it "can set from instance writer" do
      asset = Kithe::Asset.new
      asset.set_promotion_directives(promote: :inline)
      expect(asset.file_attacher.promotion_directives).to eq(promote: :inline)
    end
  end
end
