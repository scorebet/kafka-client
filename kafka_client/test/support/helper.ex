defmodule KafkaClient.Test.Helper do
  import ExUnit.Assertions

  def unique(prefix), do: "#{prefix}_#{System.unique_integer([:positive, :monotonic])}"

  def initialize_producer! do
    :ok = :brod.start_client(brokers(), :test_client, auto_start_producers: true)
  end

  def start_consumer!(opts \\ []) do
    group_id = Keyword.get(opts, :group_id, unique("test_group"))

    topics = consumer_topics(opts)

    test_pid = self()
    child_id = make_ref()

    consumer_pid =
      ExUnit.Callbacks.start_supervised!(
        {KafkaClient.Consumer,
         servers: servers(),
         group_id: group_id,
         topics: topics,
         handler: &handle_consumer_event(&1, test_pid),
         commit_interval: 50,
         consumer_params: Keyword.get(opts, :consumer_params, %{})},
        id: child_id,
        restart: :temporary
      )

    handler_id = make_ref()

    :telemetry.attach(
      handler_id,
      [:kafka_client, :consumer, :record, :queue, :start],
      fn _name, _measurements, meta, _config ->
        if hd(Process.get(:"$ancestors")) == consumer_pid, do: send(test_pid, {:polled, meta})
      end,
      nil
    )

    ExUnit.Callbacks.on_exit(fn -> :telemetry.detach(handler_id) end)

    assert_receive({:assigned, _partitions}, :timer.seconds(10))

    %{pid: consumer_pid, child_id: child_id, topics: topics}
  end

  defp consumer_topics(opts) do
    topics =
      Keyword.get_lazy(
        opts,
        :topics,
        fn ->
          Enum.map(
            1..Keyword.get(opts, :num_topics, 1)//1,
            fn _ -> new_test_topic() end
          )
        end
      )

    if Keyword.get(opts, :recreate_topics?, true), do: recreate_topics(topics)

    topics
  end

  def new_test_topic, do: unique("kafka_client_test_topic")

  def recreate_topics(topics) do
    topics
    |> Task.async_stream(
      &KafkaClient.Admin.recreate_topic(brokers(), &1, num_partitions: 2),
      timeout: :timer.seconds(10)
    )
    |> Stream.run()
  end

  defp handle_consumer_event({event_name, _} = event, test_pid)
       when event_name in ~w/assigned unassigned polled committed/a,
       do: send(test_pid, event)

  defp handle_consumer_event(:caught_up, test_pid), do: send(test_pid, :caught_up)

  defp handle_consumer_event({:record, record}, test_pid) do
    send(test_pid, {:processing, Map.put(record, :pid, self())})

    receive do
      :consume -> :ok
      {:crash, reason} -> raise reason
    end

    send(test_pid, {:processed, record.topic, record.partition, record.offset})
  end

  def stop_consumer(consumer), do: ExUnit.Callbacks.stop_supervised(consumer.child_id)

  def produce(topic, opts \\ []) do
    key = Keyword.get(opts, :key, unique("key"))
    default_opts = %{partition: 0, key: key, value: :crypto.strong_rand_bytes(4)}
    opts = Map.merge(default_opts, Map.new(opts))

    {:ok, offset} =
      :brod.produce_sync_offset(:test_client, topic, opts.partition, opts.key, opts.value)

    Map.merge(opts, %{topic: topic, offset: offset})
  end

  def resume_processing(record) do
    send(record.pid, :consume)
    %{topic: topic, partition: partition, offset: offset} = record
    assert_receive {:processed, ^topic, ^partition, ^offset}
    :ok
  end

  def crash_processing(record, reason) do
    send(record.pid, {:crash, reason})
    :ok
  end

  def assert_polled(topic, partition, offset) do
    assert_receive {:polled, %{topic: ^topic, partition: ^partition, offset: ^offset}},
                   :timer.seconds(10)
  end

  def refute_polled(topic, partition, offset) do
    refute_receive {:polled, %{topic: ^topic, partition: ^partition, offset: ^offset}},
                   :timer.seconds(1)
  end

  def assert_processing(topic, partition) do
    assert_receive {:processing, %{topic: ^topic, partition: ^partition} = record},
                   :timer.seconds(10)

    record
  end

  def refute_processing(topic, partition) do
    refute_receive {:processing, %{topic: ^topic, partition: ^partition}}
  end

  def assert_caught_up, do: assert_receive(:caught_up, :timer.seconds(10))
  def refute_caught_up, do: refute_receive(:caught_up, :timer.seconds(1))

  def process_next_record!(topic, partition) do
    record = assert_processing(topic, partition)
    resume_processing(record)
    record
  end

  def port(consumer) do
    {:ok, poller_pid} = Parent.Client.child_pid(consumer.pid, :poller)
    :sys.get_state(poller_pid).port
  end

  def os_pid(port) do
    {:os_pid, os_pid} = Port.info(port, :os_pid)
    os_pid
  end

  def servers, do: Enum.map(brokers(), fn {host, port} -> "#{host}:#{port}" end)
  defp brokers, do: [{"localhost", 9092}]
end
