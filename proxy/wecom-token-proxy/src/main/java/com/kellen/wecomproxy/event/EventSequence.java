package com.kellen.wecomproxy.event;

import java.io.IOException;
import java.io.RandomAccessFile;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

/**
 * Monotonic `eventId` for relayed callbacks, persisted synchronously so a
 * restart never re-issues a number (consumers dedupe on (corpId, eventId)).
 */
public class EventSequence {

    private final Path file;
    private long last;

    public EventSequence(Path dataDir) throws IOException {
        Files.createDirectories(dataDir);
        this.file = dataDir.resolve("event-seq");
        if (Files.exists(file)) {
            String text = Files.readString(file, StandardCharsets.UTF_8).strip();
            last = text.isEmpty() ? 0 : Long.parseLong(text);
        }
    }

    public synchronized long next() throws IOException {
        last += 1;
        try (RandomAccessFile raf = new RandomAccessFile(file.toFile(), "rws")) {
            raf.setLength(0);
            raf.write(Long.toString(last).getBytes(StandardCharsets.UTF_8));
            raf.getFD().sync();
        }
        return last;
    }

    public synchronized long last() {
        return last;
    }
}
