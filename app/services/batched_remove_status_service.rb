# frozen_string_literal: true

class BatchedRemoveStatusService < BaseService
  include StreamEntryRenderer

  # Delete given statuses and reblogs of them
  # Dispatch PuSH updates of the deleted statuses, but only local ones
  # Dispatch Salmon deletes, unique per domain, of the deleted statuses, but only local ones
  # Remove statuses from home feeds
  # Push delete events to streaming API for home feeds and public feeds
  # @param [Status] statuses A preferably batched array of statuses
  def call(statuses)
    statuses = Status.where(id: statuses.map(&:id)).includes(:account, :stream_entry).flat_map { |status| [status] + status.reblogs.includes(:account, :stream_entry).to_a }

    @mentions = statuses.map { |s| [s.id, s.mentions.includes(:account).to_a] }.to_h
    @tags     = statuses.map { |s| [s.id, s.tags.pluck(:name)] }.to_h

    @stream_entry_batches = []
    @salmon_batches       = []
    @json_payloads        = statuses.map { |s| [s.id, Oj.dump(event: :delete, payload: s.id)] }.to_h

    # Ensure that rendered XML reflects destroyed state
    Status.where(id: statuses.map(&:id)).in_batches.destroy_all

    # Batch by source account
    statuses.group_by(&:account_id).each do |_, account_statuses|
      account = account_statuses.first.account

      unpush_from_home_timelines(account, account_statuses)
      batch_stream_entries(account_statuses) if account.local?
    end

    # Cannot be batched
    statuses.each do |status|
      unpush_from_public_timelines(status)
      batch_salmon_slaps(status) if status.local?
    end

    Pubsubhubbub::DistributionWorker.push_bulk(@stream_entry_batches) { |batch| batch }
    NotificationWorker.push_bulk(@salmon_batches) { |batch| batch }
  end

  private

  def batch_stream_entries(statuses)
    stream_entry_ids = statuses.map { |s| s.stream_entry.id }

    stream_entry_ids.each_slice(100) do |batch_of_stream_entry_ids|
      @stream_entry_batches << [batch_of_stream_entry_ids]
    end
  end

  def unpush_from_home_timelines(account, statuses)
    recipients = account.followers.local.to_a

    recipients << account if account.local?

    recipients.each do |follower|
      statuses.each do |status|
        FeedManager.instance.unpush(:home, follower, status)
      end
    end
  end

  def unpush_from_public_timelines(status)
    payload = @json_payloads[status.id]

    redis.pipelined do
      redis.publish('timeline:public', payload)
      redis.publish('timeline:public:local', payload) if status.local?

      @tags[status.id].each do |hashtag|
        redis.publish("timeline:hashtag:#{hashtag}", payload)
        redis.publish("timeline:hashtag:#{hashtag}:local", payload) if status.local?
      end
    end
  end

  def batch_salmon_slaps(status)
    return if @mentions[status.id].empty?

    payload    = stream_entry_to_xml(status.stream_entry.reload)
    recipients = @mentions[status.id].map(&:account).reject(&:local?).uniq(&:domain).map(&:id)

    recipients.each do |recipient_id|
      @salmon_batches << [payload, status.account_id, recipient_id]
    end
  end

  def redis
    Redis.current
  end
end
