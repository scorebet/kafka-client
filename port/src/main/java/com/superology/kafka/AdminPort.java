package com.superology.kafka;

import java.util.*;
import java.util.concurrent.*;

import org.apache.kafka.clients.admin.*;
import org.apache.kafka.common.*;

import com.ericsson.otp.erlang.*;

/*
 * Exposes the {@link Admin} interface to Elixir.
 */
public class AdminPort implements Port {
  public static void main(String[] args) {
    System.setProperty("org.slf4j.simpleLogger.defaultLogLevel", "warn");
    PortDriver.run(args, new AdminPort());
  }

  private Map<String, Handler> dispatchMap = Map.ofEntries(
      Map.entry("stop", this::stop),
      Map.entry("describe_topics", this::describeTopics),
      Map.entry("list_topics", this::listTopics),
      Map.entry("list_end_offsets", this::listEndOffsets),
      Map.entry("list_consumer_group_offsets", this::listConsumerGroupOffsets));

  @Override
  public int run(PortWorker worker, PortOutput output, Object[] args) throws Exception {
    @SuppressWarnings("unchecked")
    var props = mapToProperties((Map<Object, Object>) args[0]);

    try (var admin = Admin.create(props)) {
      while (true) {
        var command = worker.take();
        var exitCode = dispatchMap.get(command.name()).handle(admin, command, output);
        if (exitCode != null)
          return exitCode;
      }
    }
  }

  private Integer stop(Admin admin, Port.Command command, PortOutput output) {
    return 0;
  }

  private Integer listTopics(Admin admin, Port.Command command, PortOutput output)
      throws InterruptedException, ExecutionException {
    output.emitCallResponse(
        command,
        Erlang.toList(
            admin.listTopics().names().get(),
            name -> new OtpErlangBinary(name.getBytes())));

    return null;
  }

  private Integer describeTopics(Admin admin, Port.Command command, PortOutput output)
      throws InterruptedException {
    @SuppressWarnings("unchecked")
    var topics = (Collection<String>) command.args()[0];
    OtpErlangObject response;
    try {
      var descriptions = admin.describeTopics(TopicCollection.ofTopicNames(topics));

      var map = Erlang.toMap(
          descriptions.allTopicNames().get(),
          entry -> {
            var topic = new OtpErlangBinary(entry.getKey().getBytes());
            var partitions = Erlang.toList(
                entry.getValue().partitions(),
                partition -> new OtpErlangInt(partition.partition()));
            return new AbstractMap.SimpleEntry<>(topic, partitions);
          });

      response = Erlang.ok(map);
    } catch (ExecutionException e) {
      response = Erlang.error(new OtpErlangBinary(e.getCause().getMessage().getBytes()));
    }

    output.emitCallResponse(command, response);

    return null;
  }

  private Integer listEndOffsets(Admin admin, Port.Command command, PortOutput output)
      throws InterruptedException {

    var topicPartitionOffsets = new HashMap<TopicPartition, OffsetSpec>();
    for (@SuppressWarnings("unchecked")
    var topicPartitionTuple : ((Iterable<Object[]>) command.args()[0])) {
      var topicPartition = new TopicPartition((String) topicPartitionTuple[0], (int) topicPartitionTuple[1]);
      topicPartitionOffsets.put(topicPartition, OffsetSpec.latest());
    }

    OtpErlangObject response;
    try {
      var map = Erlang.toMap(
          admin.listOffsets(topicPartitionOffsets).all().get(),
          entry -> {
            return new AbstractMap.SimpleEntry<>(
                new OtpErlangTuple(new OtpErlangObject[] {
                    new OtpErlangBinary(entry.getKey().topic().getBytes()),
                    new OtpErlangInt(entry.getKey().partition())
                }),
                new OtpErlangLong(entry.getValue().offset()));

          });
      response = Erlang.ok(map);
    } catch (ExecutionException e) {
      response = Erlang.error(new OtpErlangBinary(e.getCause().getMessage().getBytes()));
    }

    output.emitCallResponse(command, response);

    return null;
  }

  private Integer listConsumerGroupOffsets(Admin admin, Port.Command command, PortOutput output)
      throws InterruptedException {
    var topicPartitions = new LinkedList<TopicPartition>();

    for (@SuppressWarnings("unchecked")
    var topicPartitionTuple : ((Iterable<Object[]>) command.args()[1])) {
      var topicPartition = new TopicPartition((String) topicPartitionTuple[0], (int) topicPartitionTuple[1]);
      topicPartitions.add(topicPartition);
    }

    var options = new ListConsumerGroupOffsetsOptions();
    options.topicPartitions(topicPartitions);

    OtpErlangObject response;
    try {
      var map = Erlang.toMap(
          admin.listConsumerGroupOffsets((String) command.args()[0], options)
              .partitionsToOffsetAndMetadata()
              .get(),
          entry -> {
            OtpErlangObject offset;

            if (entry.getValue() == null)
              offset = new OtpErlangAtom("nil");
            else
              offset = new OtpErlangLong(entry.getValue().offset());

            return new AbstractMap.SimpleEntry<>(
                new OtpErlangTuple(new OtpErlangObject[] {
                    new OtpErlangBinary(entry.getKey().topic().getBytes()),
                    new OtpErlangInt(entry.getKey().partition())
                }),
                offset);
          });

      response = Erlang.ok(map);
    } catch (ExecutionException e) {
      response = Erlang.error(new OtpErlangBinary(e.getCause().getMessage().getBytes()));
    }

    output.emitCallResponse(command, response);

    return null;
  }

  private Properties mapToProperties(Map<Object, Object> map) {
    // need to remove nulls, because Properties doesn't support them
    map.values().removeAll(Collections.singleton(null));
    var result = new Properties();
    result.putAll(map);
    return result;
  }

  @FunctionalInterface
  interface Handler {
    Integer handle(Admin admin, Port.Command command, PortOutput output) throws Exception;
  }
}
