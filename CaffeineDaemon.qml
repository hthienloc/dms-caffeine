import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Modules.Plugins

PluginComponent {
    id: root

    property bool showToasts: (pluginData?.showToasts ?? true)
    property bool deactivateOnManualLock: (pluginData?.deactivateOnManualLock ?? true)

    PluginGlobalVar {
        id: globalIsActive
        varName: "isActive"
        defaultValue: false
    }

    PluginGlobalVar {
        id: globalTimeLeft
        varName: "timeLeft"
        defaultValue: 0
    }

    PluginGlobalVar {
        id: globalIsAutoActive
        varName: "isAutoActive"
        defaultValue: false
    }

    PluginGlobalVar {
        id: globalManualOverrideOff
        varName: "manualOverrideOff"
        defaultValue: false
    }

    Timer {
        id: countdownTimer
        interval: 1000
        repeat: true
        running: globalIsActive.value && globalTimeLeft.value > 0
        onTriggered: {
            const newVal = globalTimeLeft.value - 1;
            globalTimeLeft.set(newVal);
            if (newVal <= 0) {
                countdownTimer.stop();
                deactivateCaffeine("timeout");
            }
        }
    }

    Component.onCompleted: {
        Proc.runCommand("check-caffeine-active", ["pgrep", "-f", "DMS Caffeine"], function(output, exitCode) {
            const isActive = (exitCode === 0 && output.trim() !== "");
            if (isActive) {
                globalIsActive.set(true);
                const expiration = pluginService ? pluginService.loadPluginState(pluginId, "expiration", 0) : 0;
                if (expiration > Date.now()) {
                    globalTimeLeft.set(Math.round((expiration - Date.now()) / 1000));
                }
                if (typeof SessionService !== "undefined") {
                    SessionService.enableIdleInhibit();
                }
            } else {
                globalIsActive.set(false);
                if (pluginService) {
                    pluginService.savePluginState(pluginId, "expiration", 0);
                }
            }
        })
    }

    function deactivateCaffeine(reason) {
        if (!globalIsActive.value) return;

        globalIsActive.set(false);
        globalIsAutoActive.set(false);

        if (reason !== "preserve-override") {
            globalManualOverrideOff.set(false);
        }

        if (pluginService) {
            pluginService.savePluginState(pluginId, "expiration", 0);
        }

        Proc.runCommand("deactivate-caffeine", ["pkill", "-f", "DMS Caffeine"], function(output, exitCode) {
            if (showToasts) {
                if (reason === "battery") {
                    ToastService?.showWarning(
                        I18n.tr("Low Battery"),
                        I18n.tr("Stay awake disabled to save power.")
                    );
                } else if (reason !== "lock" && reason !== "silent") {
                    ToastService?.showInfo(I18n.tr("Screen sleep is now allowed."));
                }
            }
        });

        if (typeof SessionService !== "undefined") {
            SessionService.disableIdleInhibit();
        }
    }

    Connections {
        target: (typeof SessionService !== "undefined") ? SessionService : null
        ignoreUnknownSignals: true
        function onLockedChanged() {
            if (SessionService.locked && deactivateOnManualLock && globalIsActive.value) {
                deactivateCaffeine("lock");
            }
        }
    }

    IpcHandler {
        function toggle(duration: string) : string {
            const dur = duration && duration !== "" ? duration : undefined;
            if (globalIsActive.value) {
                deactivateCaffeine("silent");
                return "DEACTIVATED";
            } else {
                const args = [
                    "systemd-inhibit",
                    "--what=idle",
                    "--who=DMS Caffeine",
                    "--why=Manual stay awake override"
                ];
                const targetDuration = dur || "infinity";
                if (targetDuration === "infinity") {
                    args.push("sleep", "infinity");
                } else {
                    args.push("sleep", targetDuration);
                }
                Quickshell.execDetached(args);

                if (targetDuration !== "infinity") {
                    const durationSecs = parseInt(targetDuration);
                    globalTimeLeft.set(durationSecs);
                    const expiration = Date.now() + durationSecs * 1000;
                    if (pluginService) {
                        pluginService.savePluginState(pluginId, "expiration", expiration);
                    }
                } else {
                    if (pluginService) {
                        pluginService.savePluginState(pluginId, "expiration", 0);
                    }
                }

                globalIsActive.set(true);
                if (typeof SessionService !== "undefined") {
                    SessionService.enableIdleInhibit();
                }
                return "ACTIVATED (" + targetDuration + ")";
            }
        }

        function status() : string {
            if (!globalIsActive.value) return "inactive";
            if (globalIsAutoActive.value) return "auto";
            return "active";
        }

        target: "caffeine"
        enabled: true
    }
}
