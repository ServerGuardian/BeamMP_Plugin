package com.serverguardian.mc;

import java.util.Map;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;
import java.util.regex.Pattern;
import net.kyori.adventure.text.Component;
import org.bukkit.Bukkit;
import org.bukkit.entity.Player;
import org.bukkit.event.EventHandler;
import org.bukkit.event.Listener;
import org.bukkit.event.player.PlayerJoinEvent;
import org.bukkit.event.player.PlayerQuitEvent;
import org.bukkit.plugin.java.JavaPlugin;

/**
 * ServerGuardian for Paper.
 *
 * <p>When a player joins it shows the ServerGuardian notice in chat, then (off the main thread) asks
 * the ServerGuardian API whether the player may stay, and removes them if the answer is "block". The
 * server operator only ever learns pass or block. A Minecraft server has no way to show a notice
 * before the player is in, so the check starts only after the notice has been shown.
 */
public final class ServerGuardianPlugin extends JavaPlugin implements Listener {

    private static final Pattern KEY = Pattern.compile("^sg_[A-Za-z0-9]+_[A-Za-z0-9_-]+$");
    private static final Pattern BASE = Pattern.compile("^https?://[A-Za-z0-9.:-]+$");

    private GuardClient client;
    private final Map<UUID, String> joins = new ConcurrentHashMap<>();

    @Override
    public void onEnable() {
        saveDefaultConfig();
        String key = getConfig().getString("api-key", "");
        String base = getConfig().getString("api-base", "");
        if (!KEY.matcher(key).matches()) {
            disable("api-key in config.yml is missing or is not a ServerGuardian key");
            return;
        }
        if (!BASE.matcher(base).matches()) {
            disable("api-base in config.yml must look like https://api.example.com (no path)");
            return;
        }
        if (!Bukkit.getOnlineMode() && !getConfig().getBoolean("trust-offline-mode-uuids", false)) {
            disable("the server is in offline mode, so player ids cannot be trusted. Put a proxy that "
                    + "checks accounts in front and set trust-offline-mode-uuids: true in config.yml");
            return;
        }
        long timeout = Math.max(1000, Math.min(10000, getConfig().getLong("timeout-ms", 3000)));
        boolean closed = "closed".equalsIgnoreCase(getConfig().getString("fail-mode", "open"));
        client = new GuardClient(getLogger(), base, key, closed, timeout);
        getServer().getPluginManager().registerEvents(this, this);
        getServer().getScheduler().runTaskAsynchronously(this, () -> {
            client.refreshConfig(true);
            getLogger().info("Started.");
        });
    }

    private void disable(String reason) {
        getLogger().severe("Not started: " + reason);
        getServer().getPluginManager().disablePlugin(this);
    }

    @EventHandler
    public void onJoin(PlayerJoinEvent event) {
        if (client == null) {
            return;
        }
        Player player = event.getPlayer();
        UUID uuid = player.getUniqueId();
        // Read what is needed now, on the main thread. The address is never stored or logged.
        String ip = player.getAddress() == null ? null : player.getAddress().getAddress().getHostAddress();
        if (ip == null) {
            return;
        }

        // Show the notice first. Nothing is sent about the player until it has been shown.
        player.sendMessage(Component.text(client.wording().notice()));

        getServer().getScheduler().runTaskAsynchronously(this, () -> {
            client.refreshConfig(false);
            GuardClient.Decision decision = client.check(uuid, ip);
            joins.put(uuid, decision.eventId());
            if (decision.deny()) {
                // Back to the main thread to remove them.
                getServer().getScheduler().runTask(this, () -> {
                    Player online = Bukkit.getPlayer(uuid);
                    if (online != null) {
                        online.kick(Component.text(decision.message()));
                    }
                });
            }
        });
    }

    @EventHandler
    public void onQuit(PlayerQuitEvent event) {
        String eventId = joins.remove(event.getPlayer().getUniqueId());
        if (client != null && eventId != null) {
            getServer().getScheduler().runTaskAsynchronously(this, () -> client.leave(eventId));
        }
    }
}
