# A service object to add an IO stream as a derivative with a certain key, to a asset.
# Adds a Derivative database object for such. This class is normally only used from
# Asset#update_derivative, it's a helper object, you aren't expected to use it independently.
#
# This would be very straightforward if it weren't for taking account of a couple concurrency race
# conditions involving data integrity:
#
# 1. There should be only one derivative for a given asset/key pair. This is enforced by
#   a DB constraint. If the record already exists, we want to update the current record,
#   otherwise add a new one. We want to do this in a race-condition safe way, with possibly
#   multiple processes editing db.
#
# 2. The DB should at no point in time contain a derivative generated for an _old_ version
#   of the asset. If an asset#file is changed, it's existing derivatives need to be deleted,
#   and this needs to happen in a race-condition safe way when something may be trying to
#   add a derivative concurrently.
#
# I believe we have solved those challenges, but it leads to a bit tricky code. We use
# a kind of "optimistic" approach to (1) (try to insert, if you get a uniqueness violation
# try to find and use the record that's already there). And a "pessimistic" approach to (2),
# where we actually briefly take out a DB pessimistic lock to make sure the asset#file hasn't
# changed, and can't until we're done updating.  (using sha512 as a marker, which is why you
# can't add an asset until it has a sha512 in it's metadata, usually post-promotion).
#
# If we made a given Asset objects's file bytestream immutable, this would all be a lot simpler;
# we wouldn't need to worry about (2) at all, and maybe not even (1). We might consider that, but
# for now we're tackling the hard way.
#
class Kithe::Asset::DerivativeUpdater
  attr_reader :asset, :key, :io, :storage_key, :metadata, :max_optimistic_tries

  def initialize(asset, key, io, storage_key: :kithe_derivatives, metadata: {})
    @asset = asset
    @key = key
    @io = io
    @storage_key = storage_key
    @metadata = metadata

    @max_optimistic_tries = 3

    unless asset_has_persisted_sha512?
      raise ArgumentError.new("Can not safely add derivative to an asset without a persisted sha512 value")
    end
  end

  def update
    deriv = Kithe::Derivative.new(key: key.to_s, asset: asset)

    # skip cache phase, right to specified storage, but with metadata extraction.
    uploader = deriv.file_attacher.shrine_class.new(storage_key)

    # add our derivative key to context when uploading, so Kithe::DerivativeUploader can
    # use it if needed.
    uploaded_file = uploader.upload(io, record: deriv, metadata: metadata.merge(kithe_derivative_key: key))

    optimistically_save_derivative(uploaded_file: uploaded_file, derivative: deriv)
  end

  # Attaches UploadedFile to Derivative and tries to save it -- if we get a
  # unique constraint violation because a Derivative for that asset/key already existed,
  # we fetch that alredy existing one from the db and update it's actual bytestream.
  #
  # This method calls itself recursively to do that. Gives up after max_optimistic_tries,
  # at which point it'll just raise the constraint violation exception.
  def optimistically_save_derivative(uploaded_file:, derivative:, tries: 0)
    derivative.file_attacher.set(uploaded_file)
    save_deriv_ensuring_unchanged_asset(derivative)
  rescue ActiveRecord::RecordNotUnique => e
    if tries < max_optimistic_tries
      # find the one that's already there, try to attach our new file
      # to that one
      derivative = Kithe::Derivative.where(key: key.to_s, asset: asset).first || derivative
      optimistically_save_derivative(uploaded_file: uploaded_file, derivative: derivative, tries: tries + 1)
    else
      uploaded_file.delete if uploaded_file
      raise e
    end
  rescue StandardError
    # aggressively clean up our file on errors!
    uploaded_file.delete if uploaded_file
    raise e
  end

  # Save a Derivative model with some fancy DB footwork to ensure at the time
  # we save it, the original asset file it is based on is still in db unchanged,
  # in a concurrency-safe way.
  #
  # We re-fetch to ensure asset still exists, with sha512 we expect. (kithe model ensures sha512
  # exists in shrine metadata). With a pessmistic lock in a transaction. This ensures that at
  # the point we save the new derivative, the db is still in a state where the original file
  # the derivative relates to is still in the db.
  #
  # Can raise a ActiveRecord::RecordNotUnique, if derivative unique constraint is violated,
  # that is handled above here.
  def save_deriv_ensuring_unchanged_asset(deriv)
    # fancy throw/catch keep our abort rescue from being in the transaction
    catch(:kithe_unchanged_abort) do
      Kithe::Asset.transaction do
        # the file we're trying to add a derivative to doesn't exist anymore, forget it
        unless asset.acquire_lock_on_sha
          throw :kithe_unchanged_abort
        end

        deriv.save!
        return deriv
      end
    end

    # If we made it here, we've aborted
    deriv.file.delete
    return nil
  end

  def asset_has_persisted_sha512?
    asset.persisted? && asset.sha512.present? &&
    !( asset.file_data_changed? &&
         asset.file_data_change.first.try(:dig, "metadata", "sha512") !=
           asset.file_data_change.second.try(:dig, "metadata", "sha512"))
  end
end
