package com.superology.kafka.producer;

import java.util.*;
import java.util.concurrent.ExecutionException;

import org.apache.kafka.clients.producer.*;
import com.superology.kafka.port.*;

public class Main implements Port {
  public static void main(String[] args) {
    System.setProperty("org.slf4j.simpleLogger.defaultLogLevel", "warn");
    Driver.run(args, new Main());
  }

  private Map<String, Handler> dispatchMap = Map.ofEntries(
      Map.entry("stop", this::stop),
      Map.entry("send", this::send));

  @Override
  public int run(Worker worker, Output output, Object[] args) throws Exception {
    @SuppressWarnings("unchecked")
    var props = mapToProperties((Map<Object, Object>) args[0]);

    try (var producer = new Producer(props)) {
      while (true) {
        var command = worker.take();
        var exitCode = dispatchMap.get(command.name()).handle(producer, command, output);
        if (exitCode != null)
          return exitCode;
      }
    }
  }

  private Integer stop(Producer producer, Port.Command command, Output output) {
    producer.flush();
    return 0;
  }

  private Integer send(Producer producer, Port.Command command, Output output)
      throws InterruptedException, ExecutionException {
    @SuppressWarnings("unchecked")
    var record = (Map<String, Object>) command.args()[0];

    producer.send(new ProducerRecord<>(
        (String) record.get("topic"),
        (Integer) record.get("partition"),
        (Long) record.get("timestamp"),
        (byte[]) record.get("key"),
        (byte[]) record.get("value")));

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
    Integer handle(Producer producer, Port.Command command, Output output) throws Exception;
  }
}

final class Producer extends KafkaProducer<byte[], byte[]> {
  public Producer(Properties properties) {
    super(properties);
  }
}
