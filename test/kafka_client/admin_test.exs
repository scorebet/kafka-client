defmodule KafkaClient.AdminTest do
  use ExUnit.Case, async: true

  import KafkaClient.Test.Helper
  alias KafkaClient.Admin

  setup do
    admin =
      start_supervised!(
        {Admin, servers: servers()},
        id: make_ref(),
        restart: :temporary
      )

    {:ok, admin: admin}
  end

  @tag :require_kafka
  test "list_topics", ctx do
    topic = new_test_topic()
    recreate_topics([topic])
    assert topic in Admin.list_topics(ctx.admin)
  end

  @tag :require_kafka
  test "describe_topics", ctx do
    assert {:error, error} = Admin.describe_topics(ctx.admin, ["unknown_topic"])
    assert error == "This server does not host this topic-partition."

    topic1 = new_test_topic()
    topic2 = new_test_topic()

    recreate_topics([{topic1, 1}, {topic2, 2}])

    assert {:ok, topics} = Admin.describe_topics(ctx.admin, [topic1, topic2])
    assert topics == %{topic1 => [0], topic2 => [0, 1]}
  end

  @tag :require_kafka
  test "describe_topics_config", ctx do
    assert {:error, error} = Admin.describe_topics_config(ctx.admin, ["unknown_topic"])
    assert error == ""

    topic1 = new_test_topic()
    topic2 = new_test_topic()

    recreate_topics([{topic1, 1}, {topic2, 2}])

    assert {:ok, topics} = Admin.describe_topics_config(ctx.admin, [topic1, topic2])

    assert topics == %{
             topic1 => [
               {"compression.type", "producer", true},
               {"leader.replication.throttled.replicas", "", true},
               {"message.downconversion.enable", "true", true},
               {"min.insync.replicas", "1", true},
               {"segment.jitter.ms", "0", true},
               {"cleanup.policy", "delete", true},
               {"flush.ms", "9223372036854775807", true},
               {"follower.replication.throttled.replicas", "", true},
               {"segment.bytes", "1073741824", false},
               {"retention.ms", "25920000000", true},
               {"flush.messages", "9223372036854775807", true},
               {"message.format.version", "2.8-IV1", true},
               {"file.delete.delay.ms", "60000", true},
               {"max.compaction.lag.ms", "9223372036854775807", true},
               {"max.message.bytes", "52428800", false},
               {"min.compaction.lag.ms", "0", true},
               {"message.timestamp.type", "CreateTime", true},
               {"preallocate", "false", true},
               {"min.cleanable.dirty.ratio", "0.5", true},
               {"index.interval.bytes", "4096", true},
               {"unclean.leader.election.enable", "false", true},
               {"retention.bytes", "-1", true},
               {"delete.retention.ms", "86400000", true},
               {"segment.ms", "604800000", true},
               {"message.timestamp.difference.max.ms", "9223372036854775807", true},
               {"segment.index.bytes", "10485760", true}
             ],
             topic2 => [
               {"compression.type", "producer", true},
               {"leader.replication.throttled.replicas", "", true},
               {"message.downconversion.enable", "true", true},
               {"min.insync.replicas", "1", true},
               {"segment.jitter.ms", "0", true},
               {"cleanup.policy", "delete", true},
               {"flush.ms", "9223372036854775807", true},
               {"follower.replication.throttled.replicas", "", true},
               {"segment.bytes", "1073741824", false},
               {"retention.ms", "25920000000", true},
               {"flush.messages", "9223372036854775807", true},
               {"message.format.version", "2.8-IV1", true},
               {"file.delete.delay.ms", "60000", true},
               {"max.compaction.lag.ms", "9223372036854775807", true},
               {"max.message.bytes", "52428800", false},
               {"min.compaction.lag.ms", "0", true},
               {"message.timestamp.type", "CreateTime", true},
               {"preallocate", "false", true},
               {"min.cleanable.dirty.ratio", "0.5", true},
               {"index.interval.bytes", "4096", true},
               {"unclean.leader.election.enable", "false", true},
               {"retention.bytes", "-1", true},
               {"delete.retention.ms", "86400000", true},
               {"segment.ms", "604800000", true},
               {"message.timestamp.difference.max.ms", "9223372036854775807", true},
               {"segment.index.bytes", "10485760", true}
             ]
           }
  end

  @tag :require_kafka
  test "list_end_offsets", ctx do
    assert {:error, error} = Admin.list_end_offsets(ctx.admin, [{"unknown_topic", 0}])
    assert error == "This server does not host this topic-partition."

    topic1 = new_test_topic()
    topic2 = new_test_topic()
    recreate_topics([topic1, topic2])

    offset_topic1_partition0 = sync_produce!(topic1, partition: 0).offset

    sync_produce!(topic1, partition: 1)
    offset_topic1_partition1 = sync_produce!(topic1, partition: 1).offset

    topic_partitions = [{topic1, 0}, {topic1, 1}, {topic2, 0}]
    assert {:ok, mapping} = Admin.list_end_offsets(ctx.admin, topic_partitions)

    assert mapping == %{
             {topic1, 0} => offset_topic1_partition0 + 1,
             {topic1, 1} => offset_topic1_partition1 + 1,
             {topic2, 0} => 0
           }
  end

  @tag :require_kafka
  test "list_earliest_offsets", ctx do
    assert {:error, error} = Admin.list_end_offsets(ctx.admin, [{"unknown_topic", 0}])
    assert error == "This server does not host this topic-partition."

    topic1 = new_test_topic()
    topic2 = new_test_topic()
    recreate_topics([topic1, topic2])

    topic_partitions = [{topic1, 0}, {topic1, 1}, {topic2, 0}]
    assert {:ok, mapping} = Admin.list_end_offsets(ctx.admin, topic_partitions)

    assert mapping == %{
             {topic1, 0} => 0,
             {topic1, 1} => 0,
             {topic2, 0} => 0
           }
  end

  @tag :require_kafka
  test "list_consumer_groups", ctx do
    consumer = start_consumer!()
    group_id = consumer.group_id

    {:ok, consumer_groups} = Admin.list_consumer_groups(ctx.admin)
    assert {group_id, :stable} in consumer_groups

    KafkaClient.Consumer.stop(consumer.pid)

    {:ok, consumer_groups} = Admin.list_consumer_groups(ctx.admin)
    assert {group_id, :empty} in consumer_groups
  end

  @tag :require_kafka
  test "delete_consumer_groups", ctx do
    consumer_1 = start_consumer!()
    group_id_1 = consumer_1.group_id

    consumer_2 = start_consumer!()
    group_id_2 = consumer_2.group_id
    KafkaClient.Consumer.stop(consumer_2.pid)

    {:ok, deleted_groups_result} =
      Admin.delete_consumer_groups(ctx.admin, [group_id_1, group_id_2])

    assert deleted_groups_result == %{
             group_id_1 => {:error, "The group is not empty."},
             group_id_2 => :ok
           }

    {:ok, consumer_groups} = Admin.list_consumer_groups(ctx.admin)
    refute Enum.any?(consumer_groups, fn {group_id, _} -> group_id == group_id_2 end)
  end

  @tag :require_kafka
  test "describe_consumer_groups", ctx do
    consumer = start_consumer!()
    group_id = consumer.group_id

    {:ok, consumer_groups} = Admin.describe_consumer_groups(ctx.admin, [consumer.group_id])

    assert consumer_groups[group_id].state == :stable
    KafkaClient.Consumer.stop(consumer.pid)

    {:ok, consumer_groups} = Admin.describe_consumer_groups(ctx.admin, [consumer.group_id])
    assert %{group_id => %{members: [], state: :empty}} == consumer_groups
  end

  @tag :require_kafka
  test "list_consumer_group_offsets", ctx do
    consumer = start_consumer!()
    [topic] = consumer.subscriptions

    sync_produce!(topic, partition: 0)
    sync_produce!(topic, partition: 0)
    sync_produce!(topic, partition: 0)
    last_processed_offset_partition_0 = process_next_record!(topic, 0).offset

    stop_supervised!(consumer.child_id)

    group_id = consumer.group_id
    topics = [{topic, 0}, {topic, 1}]
    assert {:ok, committed} = Admin.list_consumer_group_offsets(ctx.admin, group_id, topics)
    assert committed == %{{topic, 0} => last_processed_offset_partition_0 + 1, {topic, 1} => nil}
  end

  @tag :require_kafka
  test "stop", ctx do
    mref = Process.monitor(ctx.admin)
    Admin.stop(ctx.admin)
    assert_receive {:DOWN, ^mref, :process, _pid, _reason}
  end
end
