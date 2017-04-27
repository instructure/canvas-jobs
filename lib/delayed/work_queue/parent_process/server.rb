module Delayed
module WorkQueue
class ParentProcess
  class Server
    attr_reader :clients, :listen_socket

    include Delayed::Logging

    def initialize(listen_socket, parent_pid: nil, config: Settings.parent_process)
      @listen_socket = listen_socket
      @parent_pid = parent_pid
      @clients = {}
      @waiting_clients = {}
      @prefetched_jobs = {}

      @config = config
      @client_timeout = config['server_socket_timeout'] || 10.0 # left for backwards compat
    end

    def connected_clients
      @clients.size
    end

    def all_workers_idle?
      !@clients.any? { |_, c| c.working }
    end

    # run the server queue worker
    # this method does not return, only exits or raises an exception
    def run
      logger.debug "Starting work queue process"

      last_orphaned_prefetched_jobs_purge = Job.db_time_now - rand(15 * 60)
      while !exit?
        run_once
        if last_orphaned_prefetched_jobs_purge + 15 * 60 < Job.db_time_now
          Job.unlock_orphaned_prefetched_jobs
          last_orphaned_prefetched_jobs_purge = Job.db_time_now
        end
      end

    rescue => e
      logger.debug "WorkQueue Server died: #{e.inspect}", :error
      raise
    ensure
      unlock_all_prefetched_jobs
    end

    def run_once
      handles = @clients.keys + [@listen_socket]
      timeout = Settings.sleep_delay + (rand * Settings.sleep_delay_stagger)
      readable, _, _ = IO.select(handles, nil, nil, timeout)
      if readable
        readable.each { |s| handle_read(s) }
      end
      check_for_work
      unlock_timed_out_prefetched_jobs
    end

    def handle_read(socket)
      if socket == @listen_socket
        handle_accept
      else
        handle_request(socket)
      end
    end

    # Any error on the listen socket other than WaitReadable will bubble up
    # and terminate the work queue process, to be restarted by the parent daemon.
    def handle_accept
      socket, _addr = @listen_socket.accept_nonblock
      if socket
        @clients[socket] = ClientState.new(false, socket)
      end
    rescue IO::WaitReadable
      logger.error("Server attempted to read listen_socket but failed with IO::WaitReadable")
      # ignore and just try accepting again next time through the loop
    end

    def handle_request(socket)
      # There is an assumption here that the client will never send a partial
      # request and then leave the socket open. Doing so would leave us hanging
      # in Marshal.load forever. This is only a reasonable assumption because we
      # control the client.
      return drop_socket(socket) if socket.eof?
      worker_name, worker_config = Marshal.load(socket)
      client = @clients[socket]
      client.name = worker_name
      client.working = false
      (@waiting_clients[worker_config] ||= []) << client
    rescue SystemCallError, IOError => ex
      logger.error("Receiving message from client (#{socket}) failed: #{ex.inspect}")
      drop_socket(socket)
    end

    def check_for_work
      @waiting_clients.each do |(worker_config, workers)|
        prefetched_jobs = @prefetched_jobs[worker_config] ||= []
        logger.debug("I have #{prefetched_jobs.length} jobs for #{workers.length} waiting workers")
        while !prefetched_jobs.empty? && !workers.empty?
          job = prefetched_jobs.shift
          client = workers.shift
          # couldn't re-lock it for some reason
          unless job.transfer_lock!(from: prefetch_owner, to: client.name)
            workers.unshift(client)
            next
          end
          begin
            client_timeout { Marshal.dump(job, client.socket) }
          rescue SystemCallError, IOError, Timeout::Error => ex
            logger.error("Failed to send pre-fetched job to #{client.name}: #{ex.inspect}")
            drop_socket(client.socket)
            Delayed::Job.unlock([job])
          end
        end

        next if workers.empty?

        Delayed::Worker.lifecycle.run_callbacks(:work_queue_pop, self, worker_config) do
          recipients = workers.map(&:name)

          response = Delayed::Job.get_and_lock_next_available(
              recipients,
              worker_config[:queue],
              worker_config[:min_priority],
              worker_config[:max_priority],
              prefetch: Settings.fetch_batch_size * (worker_config[:workers] || 1) - recipients.length,
              prefetch_owner: prefetch_owner)
          response.each do |(worker_name, job)|
            if worker_name == prefetch_owner
              # it's actually an array of all the extra jobs
              prefetched_jobs.concat(job)
              next
            end
            client = workers.find { |worker| worker.name == worker_name }
            client.working = true
            @waiting_clients[worker_config].delete(client)
            begin
              client_timeout { Marshal.dump(job, client.socket) }
            rescue SystemCallError, IOError, Timeout::Error => ex
              logger.error("Failed to send job to #{client.name}: #{ex.inspect}")
              drop_socket(client.socket)
              Delayed::Job.unlock([job])
            end
          end
        end
      end
    end

    def unlock_timed_out_prefetched_jobs
      @prefetched_jobs.each do |(worker_config, jobs)|
        next if jobs.empty?
        if jobs.first.locked_at < Time.now.utc - Settings.parent_process[:prefetched_jobs_timeout]
          Delayed::Job.unlock(jobs)
          @prefetched_jobs[worker_config] = []
        end
      end
    end

    def unlock_all_prefetched_jobs
      @prefetched_jobs.each do |(_worker_config, jobs)|
        next if jobs.empty?
        Delayed::Job.unlock(jobs)
      end
      @prefetched_jobs = {}
    end

    def drop_socket(socket)
      # this socket went away
      begin
        socket.close
      rescue IOError
      end
      client = @clients[socket]
      @clients.delete(socket)
      @waiting_clients.each do |(_config, workers)|
        workers.delete(client)
      end
    end

    def exit?
      parent_exited?
    end

    def prefetch_owner
      "prefetch:#{Socket.gethostname rescue 'X'}"
    end

    def parent_exited?
      @parent_pid && @parent_pid != Process.ppid
    end

    def client_timeout
      Timeout.timeout(@client_timeout) { yield }
    end

    ClientState = Struct.new(:working, :socket, :name)
  end
end
end
end
