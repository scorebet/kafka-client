defmodule KafkaClient.AdminTest do
  use ExUnit.Case, async: true

  import KafkaClient.Test.Helper
  alias KafkaClient.Admin

  @moduletag :require_kafka

  setup do
    admin =
      start_supervised!(
        {Admin, servers: servers()},
        id: make_ref(),
        restart: :temporary
      )

    {:ok, admin: admin}
  end

  test "list_topics", ctx do
    topic = new_test_topic()
    recreate_topics([topic])
    assert topic in Admin.list_topics(ctx.admin)
  end

  test "describe_topics", ctx do
    assert {:error, error} = Admin.describe_topics(ctx.admin, ["unknown_topic"])
    assert error == "This server does not host this topic-partition."

    topic1 = new_test_topic()
    topic2 = new_test_topic()

    recreate_topics([{topic1, 1}, {topic2, 2}])

    assert {:ok, topics} = Admin.describe_topics(ctx.admin, [topic1, topic2])
    assert topics == %{topic1 => [0], topic2 => [0, 1]}
  end

  test "describe_topics_config", ctx do
    assert {:error, error} = Admin.describe_topics_config(ctx.admin, ["unknown_topic"])
    assert error == ""

    topic1 = new_test_topic()
    topic2 = new_test_topic()

    recreate_topics([{topic1, 1}, {topic2, 2}])

    assert {:ok, topics} = Admin.describe_topics_config(ctx.admin, [topic1, topic2])

    assert map_size(topics) == 2
    assert is_list(topics[topic1])
    assert %{is_default: true, name: "cleanup.policy", value: "delete"} in topics[topic1]
    assert %{is_default: true, name: "retention.ms", value: "25920000000"} in topics[topic1]
  end

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

  test "list_consumer_groups", ctx do
    consumer = start_consumer!()
    group_id = consumer.group_id

    {:ok, consumer_groups} = Admin.list_consumer_groups(ctx.admin)
    assert {group_id, :stable} in consumer_groups

    KafkaClient.Consumer.stop(consumer.pid)

    {:ok, consumer_groups} = Admin.list_consumer_groups(ctx.admin)
    assert {group_id, :empty} in consumer_groups
  end

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

  test "list_consumer_group_offsets", ctx do
    consumer = start_consumer!()
    [topic] = consumer.subscriptions

    sync_produce!(topic, partition: 0)
    sync_produce!(topic, partition: 0)
    sync_produce!(topic, partition: 0)
    last_processed_offset_partition_0 = hd(process_next_batch!(topic, 0).records).offset

    stop_supervised!(consumer.child_id)

    group_id = consumer.group_id
    topics = [{topic, 0}, {topic, 1}]
    assert {:ok, committed} = Admin.list_consumer_group_offsets(ctx.admin, group_id, topics)
    assert committed == %{{topic, 0} => last_processed_offset_partition_0 + 1, {topic, 1} => nil}
  end

  test "stop", ctx do
    mref = Process.monitor(ctx.admin)
    Admin.stop(ctx.admin)
    assert_receive {:DOWN, ^mref, :process, _pid, _reason}
  end
end
