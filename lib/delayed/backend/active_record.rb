class ActiveRecord::Base
  def self.load_for_delayed_job(id)
    if id
      find(id)
    else
      super
    end
  end
end

module Delayed
  module Backend
    module ActiveRecord
      # A job object that is persisted to the database.
      # Contains the work object as a YAML field.
      class Job < ::ActiveRecord::Base
        include Delayed::Backend::Base
        self.table_name = :delayed_jobs

        def self.reconnect!
          clear_all_connections!
        end

        # be aware that some strand functionality is controlled by triggers on
        # the database. see
        # db/migrate/20110831210257_add_delayed_jobs_next_in_strand.rb
        #
        # next_in_strand defaults to true. if we insert a new job, and it has a
        # strand, and it's not the next in the strand, we set it to false.
        #
        # if we delete a job, and it has a strand, mark the next job in that
        # strand to be next_in_strand
        # (this is safe even if we're not deleting the job that was currently
        # next_in_strand)

        # postgresql needs this lock to be taken before the before_insert
        # trigger starts, or we risk deadlock inside of the trigger when trying
        # to raise the lock level
        before_create :lock_strand_on_create
        def lock_strand_on_create
          if strand.present?
            self.class.connection.execute("SELECT pg_advisory_xact_lock(#{self.class.connection.quote_table_name('half_md5_as_bigint')}(#{self.class.sanitize(strand)}))")
          end
        end

        # This overwrites the previous behavior
        # so rather than changing the strand and balancing at queue time,
        # this keeps the strand intact and uses triggers to limit the number running
        def self.n_strand_options(strand_name, num_strands)
          {:strand => strand_name, :max_concurrent => num_strands}
        end

        def self.current
          where("run_at<=?", db_time_now)
        end

        def self.future
          where("run_at>?", db_time_now)
        end

        def self.failed
          where("failed_at IS NOT NULL")
        end

        def self.running
          where("locked_at IS NOT NULL AND locked_by<>'on hold'")
        end

        # a nice stress test:
        # 10_000.times { |i| Kernel.send_later_enqueue_args(:system, { :strand => 's1', :run_at => (24.hours.ago + (rand(24.hours.to_i))) }, "echo #{i} >> test1.txt") }
        # 500.times { |i| "ohai".send_later_enqueue_args(:reverse, { :run_at => (12.hours.ago + (rand(24.hours.to_i))) }) }
        # then fire up your workers
        # you can check out strand correctness: diff test1.txt <(sort -n test1.txt)
         def self.ready_to_run
           where("run_at<=? AND locked_at IS NULL AND next_in_strand=?", db_time_now, true)
         end
        def self.by_priority
          order("priority ASC, run_at ASC")
        end

        # When a worker is exiting, make sure we don't have any locked jobs.
        def self.clear_locks!(worker_name)
          where(:locked_by => worker_name).update_all(:locked_by => nil, :locked_at => nil)
        end

        def self.strand_size(strand)
          self.where(:strand => strand).count
        end

        def self.running_jobs()
          self.running.order(:locked_at)
        end

        def self.scope_for_flavor(flavor, query)
          scope = case flavor.to_s
          when 'current'
            self.current
          when 'future'
            self.future
          when 'failed'
            Delayed::Job::Failed
          when 'strand'
            self.where(:strand => query)
          when 'tag'
            self.where(:tag => query)
          else
            raise ArgumentError, "invalid flavor: #{flavor.inspect}"
          end

          if %w(current future).include?(flavor.to_s)
            queue = query.presence || Delayed::Settings.queue
            scope = scope.where(:queue => queue)
          end

          scope
        end

        # get a list of jobs of the given flavor in the given queue
        # flavor is :current, :future, :failed, :strand or :tag
        # depending on the flavor, query has a different meaning:
        # for :current and :future, it's the queue name (defaults to Delayed::Settings.queue)
        # for :strand it's the strand name
        # for :tag it's the tag name
        # for :failed it's ignored
        def self.list_jobs(flavor,
                           limit,
                           offset = 0,
                           query = nil)
          scope = self.scope_for_flavor(flavor, query)
          order = flavor.to_s == 'future' ? 'run_at' : 'id desc'
          scope.order(order).limit(limit).offset(offset).to_a
        end

        # get the total job count for the given flavor
        # see list_jobs for documentation on arguments
        def self.jobs_count(flavor,
                            query = nil)
          scope = self.scope_for_flavor(flavor, query)
          scope.count
        end

        # perform a bulk update of a set of jobs
        # action is :hold, :unhold, or :destroy
        # to specify the jobs to act on, either pass opts[:ids] = [list of job ids]
        # or opts[:flavor] = <some flavor> to perform on all jobs of that flavor
        def self.bulk_update(action, opts)
          raise("Can't #{action.to_s} failed jobs") if opts[:flavor].to_s == 'failed' && action.to_s != 'destroy'
          scope = if opts[:ids]
            if opts[:flavor] == 'failed'
              Delayed::Job::Failed.where(:id => opts[:ids])
            else
              self.where(:id => opts[:ids])
            end
          elsif opts[:flavor]

            self.scope_for_flavor(opts[:flavor], opts[:query])
          end

          return 0 unless scope

          case action.to_s
          when 'hold'
            scope = scope.where(locked_by: nil)
            scope.update_all(:locked_by => ON_HOLD_LOCKED_BY, :locked_at => db_time_now, :attempts => ON_HOLD_COUNT)
          when 'unhold'
            now = db_time_now
            scope = scope.where(locked_by: ON_HOLD_LOCKED_BY)
            scope.update_all(["locked_by = NULL, locked_at = NULL, attempts = 0, run_at = (CASE WHEN run_at > ? THEN run_at ELSE ? END), failed_at = NULL", now, now])
          when 'destroy'
            scope = scope.where("locked_by IS NULL OR locked_by=?", ON_HOLD_LOCKED_BY)
            scope.delete_all
          end
        end

        # returns a list of hashes { :tag => tag_name, :count => current_count }
        # in descending count order
        # flavor is :current or :all
        def self.tag_counts(flavor,
                            limit,
                            offset = 0)
          raise(ArgumentError, "invalid flavor: #{flavor}") unless %w(current all).include?(flavor.to_s)
          scope = case flavor.to_s
            when 'current'
              self.current
            when 'all'
              self
            end

          scope = scope.group(:tag).offset(offset).limit(limit)
          scope.order("COUNT(tag) DESC").count.map { |t,c| { :tag => t, :count => c } }
        end

        def self.get_and_lock_next_available(worker_name,
                                             queue = Delayed::Settings.queue,
                                             min_priority = nil,
                                             max_priority = nil)

          check_queue(queue)
          check_priorities(min_priority, max_priority)

          loop do
            jobs = with_ar_log_silence do
              find_available(Settings.fetch_batch_size, queue, min_priority, max_priority)
            end

            return nil if jobs.empty?
            if Settings.select_random_from_batch
              jobs = jobs.sort_by { rand }
            end
            job = jobs.detect do |job|
              job.send(:lock_exclusively!, worker_name)
            end
            return job if job
          end
        end

        def self.with_ar_log_silence
          if ENV['CANVAS_JOBS_POLLING_SILENCE']
            ::ActiveRecord::Base.logger.silence { yield }
          else
            yield
          end
        end

        def self.find_available(limit,
                                queue = Delayed::Settings.queue,
                                min_priority = nil,
                                max_priority = nil)
          all_available(queue, min_priority, max_priority).limit(limit).to_a
        end

        def self.all_available(queue = Delayed::Settings.queue,
                               min_priority = nil,
                               max_priority = nil)
          min_priority ||= Delayed::MIN_PRIORITY
          max_priority ||= Delayed::MAX_PRIORITY

          check_queue(queue)
          check_priorities(min_priority, max_priority)

          self.ready_to_run.
              where(:priority => min_priority..max_priority, :queue => queue).
              by_priority
        end

        # used internally by create_singleton to take the appropriate lock
        # depending on the db driver
        def self.transaction_for_singleton(strand)
          self.transaction do
            connection.execute(sanitize_sql(["SELECT pg_advisory_xact_lock(#{connection.quote_table_name('half_md5_as_bigint')}(?))", strand]))
            yield
          end
        end

        # Create the job on the specified strand, but only if there aren't any
        # other non-running jobs on that strand.
        # (in other words, the job will still be created if there's another job
        # on the strand but it's already running)
        def self.create_singleton(options)
          strand = options[:strand]
          transaction_for_singleton(strand) do
            job = self.where(:strand => strand, :locked_at => nil).order(:id).first
            new_job = new(options)
            if job
              new_job.initialize_defaults
              job.run_at = [job.run_at, new_job.run_at].min
              job.save! if job.changed?
            else
              new_job.save!
            end
            job || new_job
          end
        end

        # Lock this job for this worker.
        # Returns true if we have the lock, false otherwise.
        #
        # It's important to note that for performance reasons, this method does
        # not re-check the strand constraints -- so you could manually lock a
        # job using this method that isn't the next to run on its strand.
        def lock_exclusively!(worker)
          now = self.class.db_time_now
          # We don't own this job so we will update the locked_by name and the locked_at
          affected_rows = self.class.where("id=? AND locked_at IS NULL AND run_at<=?", self, now).update_all(:locked_at => now, :locked_by => worker)
          if affected_rows == 1
            mark_as_locked!(now, worker)
            return true
          else
            return false
          end
        end

        def mark_as_locked!(time, worker)
          self.locked_at    = time
          self.locked_by    = worker
          # We cheated ActiveRecord::Dirty with the update_all calls above, so
          # we'll fix things up here.
          if respond_to?(:changes_applied)
            changes_applied
          else
            changed_attributes['locked_at'] = time
            changed_attributes['locked_by'] = worker
          end
        end
        protected :lock_exclusively!, :mark_as_locked!

        def create_and_lock!(worker)
          raise "job already exists" unless new_record?
          self.locked_at = Delayed::Job.db_time_now
          self.locked_by = worker
          save!
        end

        def fail!
          attrs = self.attributes
          attrs['original_job_id'] = attrs.delete('id')
          attrs['failed_at'] ||= self.class.db_time_now
          attrs.delete('next_in_strand')
          attrs.delete('max_concurrent')
          self.class.transaction do
            failed_job = Failed.create(attrs)
            self.destroy
            failed_job
          end
        rescue
          # we got an error while failing the job -- we need to at least get
          # the job out of the queue
          self.destroy
          # re-raise so the worker logs the error, at least
          raise
        end

        class Failed < Job
          include Delayed::Backend::Base
          self.table_name = :failed_jobs
        end
      end

    end
  end
end
