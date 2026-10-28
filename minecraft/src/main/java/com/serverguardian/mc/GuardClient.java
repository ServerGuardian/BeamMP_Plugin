package com.serverguardian.mc;

import com.google.gson.Gson;
import com.google.gson.JsonArray;
import com.google.gson.JsonObject;
import java.io.IOException;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.security.SecureRandom;
import java.time.Duration;
import java.util.HexFormat;
import java.util.UUID;
import java.util.logging.Logger;

/**
 * Talks to the ServerGuardian API. Blocking: call it off the main thread.
 *
 * <p>Privacy rules, the same as the other mods (docs/mods.md): nothing about a player is ever
 * logged, nothing but the join-check fields is sent, and a removed player is only told the fixed
 * wording from the API, never why.
 */
final class GuardClient {

    /** The player-facing wording. Replaced by what the API serves; this is only the fallback. */
    record Wording(String noticeVersion, String notice, String blocked) {
        static final Wording DEFAULT = new Wording(
                "notice-v1",
                "This server uses ServerGuardian. We check your connection details against accounts "
                        + "banned elsewhere. The server only learns pass or block. Please leave if you "
                        + "do not want this.",
                "You cannot join this server right now.");
    }

    /** What to do with a player. {@code message} is set when they are to be removed. */
    record Decision(boolean deny, String eventId, String message) {}

    private final HttpClient http;
    private final Gson gson = new Gson();
    private final SecureRandom random = new SecureRandom();
    private final Logger log;
    private final String apiBase;
    private final String apiKey;
    private final Duration timeout;

    private volatile Wording wording = Wording.DEFAULT;
    private volatile boolean failClosed;
    private volatile long configFetchedAt = 0;

    GuardClient(Logger log, String apiBase, String apiKey, boolean failClosed, long timeoutMs) {
        this.log = log;
        this.apiBase = apiBase;
        this.apiKey = apiKey;
        this.failClosed = failClosed;
        this.timeout = Duration.ofMillis(timeoutMs);
        this.http = HttpClient.newBuilder().connectTimeout(timeout).build();
    }

    Wording wording() {
        return wording;
    }

    /** Loads the wording and the server's fail mode. Keeps the previous values on any failure. */
    void refreshConfig(boolean force) {
        long now = System.currentTimeMillis();
        if (!force && now - configFetchedAt < Duration.ofHours(1).toMillis()) {
            return;
        }
        try {
            HttpResponse<String> response = send("GET", "/v1/mod/config", null);
            if (response.statusCode() == 200) {
                JsonObject root = gson.fromJson(response.body(), JsonObject.class);
                JsonObject en = root.getAsJsonObject("text").getAsJsonObject("en");
                this.wording = new Wording(
                        root.get("noticeVersion").getAsString(),
                        en.get("notice").getAsString(),
                        en.get("blocked").getAsString());
                if (root.has("failMode")) {
                    this.failClosed = "closed".equals(root.get("failMode").getAsString());
                }
                this.configFetchedAt = now;
                return;
            }
        } catch (IOException | RuntimeException e) {
            // Fall through to the warning. The exception text is not logged: it can contain the address.
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
        log.warning("Could not load ServerGuardian settings, using the built-in wording.");
    }

    /**
     * Asks whether a player may stay. Any failure (no answer in time, refusal, an answer we do not
     * understand) is decided by the fail mode, so the player is only removed for an explicit "block"
     * or, in closed mode, when we cannot tell. A plan or rate limit (402, 429) always lets them stay.
     */
    Decision check(UUID uuid, String ip) {
        String eventId = "mc-" + HexFormat.of().toHexDigits(System.currentTimeMillis() / 1000)
                + "-" + HexFormat.of().toHexDigits((short) random.nextInt(0x10000));

        JsonObject platformId = new JsonObject();
        platformId.addProperty("type", "minecraft_uuid");
        platformId.addProperty("id", uuid.toString().replace("-", "").toLowerCase());
        JsonArray platformIds = new JsonArray();
        platformIds.add(platformId);
        JsonObject body = new JsonObject();
        body.addProperty("eventId", eventId);
        body.addProperty("ip", ip);
        body.add("platformIds", platformIds);
        // No hardware id: a Minecraft server cannot read one, so none is ever sent.

        try {
            HttpResponse<String> response = send("POST", "/v1/join-check", body);
            if (response.statusCode() == 200) {
                String result = gson.fromJson(response.body(), JsonObject.class).get("result").getAsString();
                if ("block".equals(result)) {
                    return new Decision(true, eventId, wording.blocked());
                }
                if ("pass".equals(result)) {
                    return new Decision(false, eventId, null);
                }
            }
            // A limit of ours, not an outage: the plan's monthly allowance is used up (429) or the
            // server is over its plan (402). Players stay whatever the fail mode, so that billing
            // never locks a server's own players out.
            if (response.statusCode() == 429 || response.statusCode() == 402) {
                log.warning("Join check not done: plan or rate limit (status " + response.statusCode()
                        + "), letting the player in.");
                return new Decision(false, eventId, null);
            }
        } catch (IOException | RuntimeException e) {
            // Handled as a failure below.
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
        log.warning("Join check failed, failing " + (failClosed ? "closed" : "open") + ".");
        return failClosed ? new Decision(true, eventId, wording.blocked()) : new Decision(false, eventId, null);
    }

    /** Best effort: nothing depends on it. */
    void leave(String eventId) {
        JsonObject body = new JsonObject();
        body.addProperty("eventId", eventId);
        try {
            send("POST", "/v1/events/player-leave", body);
        } catch (IOException | RuntimeException e) {
            // Ignored on purpose.
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
    }

    private HttpResponse<String> send(String method, String path, JsonObject body)
            throws IOException, InterruptedException {
        HttpRequest.Builder request = HttpRequest.newBuilder(URI.create(apiBase + path))
                .timeout(timeout)
                .header("Authorization", "Bearer " + apiKey)
                .header("Content-Type", "application/json");
        if (body == null) {
            request.method(method, HttpRequest.BodyPublishers.noBody());
        } else {
            request.method(method, HttpRequest.BodyPublishers.ofString(gson.toJson(body)));
        }
        return http.send(request.build(), HttpResponse.BodyHandlers.ofString());
    }
}
