module VCAP::CloudController
  class ServiceInstanceBindingManager
    def initialize(services_event_repository, access_validator)
      @services_event_repository = services_event_repository
      @access_validator = access_validator
    end

    def create_service_instance_binding(request_attrs)
      service_instance = ServiceInstance.find(guid: request_attrs['service_instance_guid'])
      raise VCAP::Errors::ApiError.new_from_details('ServiceInstanceNotFound', request_attrs['service_instance_guid']) unless service_instance
      raise VCAP::Errors::ApiError.new_from_details('UnbindableService') unless service_instance.bindable?
      validate_app(request_attrs['app_guid'])

      service_binding = ServiceBinding.new(request_attrs)
      @access_validator.validate_access(:create, service_binding)
      raise Sequel::ValidationFailed.new(service_binding) if !service_binding.valid?

      begin
        lock_service_instance_by_blocking(service_instance) do
          attributes_to_update = service_binding.client.bind(service_binding)
          service_binding.set_all(attributes_to_update)
          service_binding.save
        end
      rescue
        service_binding.client.orphan_mitigator.cleanup_failed_bind(
          service_binding.client.attrs,
          service_binding
        )
        raise
      end
    end

    def delete_service_instance_binding(service_binding, params)
      service_instance = ServiceInstance.find(guid: service_binding.service_instance_guid)

      lock_service_instance_by_blocking(service_instance) do
        deletion_job = Jobs::Runtime::ModelDeletion.new(ServiceBinding, service_binding.guid)
        delete_and_audit_job = Jobs::AuditEventJob.new(deletion_job, @services_event_repository, :record_service_binding_event, :delete, service_binding)

        enqueue_deletion_job(delete_and_audit_job, params)
      end
    end

    private

    def async?(params)
      params['async'] == 'true'
    end

    def validate_app(app_guid)
      app = App.find(guid: app_guid)
      raise VCAP::Errors::ApiError.new_from_details('AppNotFound', app_guid) unless app
    end

    def enqueue_deletion_job(deletion_job, params)
      if async?(params)
        Jobs::Enqueuer.new(deletion_job, queue: 'cc-generic').enqueue
      else
        deletion_job.perform
        nil
      end
    end

    def lock_service_instance_by_blocking(service_instance, &block)
      if service_instance.managed_instance?
        service_instance.lock_by_blocking_other_operations(&block)
      else
        block.call
      end
    end
  end
end
