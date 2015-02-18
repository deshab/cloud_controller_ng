module VCAP::CloudController
  class DropletDelete
    def delete(droplet)
      blobstore_delete = Jobs::Runtime::BlobstoreDelete.new(droplet.blobstore_key, :droplet_blobstore, nil)
      Jobs::Enqueuer.new(blobstore_delete, queue: 'cc-generic').enqueue
      droplet.destroy
    end
  end
end
