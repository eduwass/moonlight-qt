// Fork-only (eduwass/moonlight-qt): which network the stream travels over.
//
// Moonlight tries a host's saved addresses in turn and uses the first that
// answers, so a stream can end up on Wi-Fi or a VPN while a cable to the same
// host sits unused, and nothing shows it: the picture is the same, only
// slower. This names the path in the log when a session starts and in the
// statistics overlay (Ctrl+Alt+Shift+S).

#include <QHostAddress>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QNetworkInterface>
#include <QProcess>
#include <QUdpSocket>

#include "chrome.h"

#include "SDL_compat.h"

static char s_Path[96] = "unknown";
static int s_Link = CHROME_OTHER;
static bool s_Relayed;

int netPathLink() { return s_Link; }
bool netPathRelayed() { return s_Relayed; }

static int linkOf(const QNetworkInterface& nic)
{
    QString name = nic.name();
    if (name.startsWith("utun") || name.startsWith("tun") || name.startsWith("wg") || name.startsWith("tailscale")) {
        return CHROME_TAILSCALE;
    }
#ifdef Q_OS_DARWIN
    if (name.startsWith("bridge")) {
        return CHROME_THUNDERBOLT;
    }
#endif
    return nic.type() == QNetworkInterface::Wifi ? CHROME_WIFI :
           nic.type() == QNetworkInterface::Ethernet ? CHROME_ETHERNET : CHROME_OTHER;
}

// Tailscale says for every peer whether it reaches it directly or through one
// of its relays, which is slower and worth a warning by itself. Asked once per
// session, from the command line tool: a second at most.
static bool tailscaleRelays(const QString& host)
{
    for (const char* tool : {"/Applications/Tailscale.app/Contents/MacOS/Tailscale", "tailscale"}) {
        QProcess status;
        status.start(tool, {"status", "--json"});
        if (!status.waitForFinished(1000)) {
            status.kill();
            status.waitForFinished(200);
            continue;
        }
        const QJsonObject peers = QJsonDocument::fromJson(status.readAllStandardOutput()).object()["Peer"].toObject();
        for (const QJsonValue& peer : peers) {
            if (peer["TailscaleIPs"].toArray().contains(host)) {
                return peer["CurAddr"].toString().isEmpty();
            }
        }
    }
    return false;
}

static const char* kindOf(const QNetworkInterface& nic)
{
    QString name = nic.name();
    if (name.startsWith("utun") || name.startsWith("tun") || name.startsWith("wg") || name.startsWith("tailscale")) {
        return "VPN";
    }
#ifdef Q_OS_DARWIN
    // macOS puts Thunderbolt networking behind a bridge, and Internet Sharing
    // too, so this is a likelihood and worded as one.
    if (name.startsWith("bridge")) {
        return "bridge, usually Thunderbolt";
    }
#endif
    switch (nic.type()) {
    case QNetworkInterface::Wifi:
        return "Wi-Fi";
    case QNetworkInterface::Ethernet:
        return "Ethernet";
    default:
        return "other";
    }
}

const char* netPath()
{
    return s_Path;
}

void netPathUpdate(const QString& host)
{
    QByteArray via = "unknown interface";
    s_Link = CHROME_OTHER;
    s_Relayed = false;

    // Only for a literal address: a name would have to be resolved, which can
    // block, and could resolve to another address than the stream uses.
    QHostAddress local;
    if (!QHostAddress(host).isNull()) {
        // Connecting a UDP socket sends nothing. It only makes the system
        // choose the local address it would reach the host from.
        QUdpSocket probe;
        probe.connectToHost(host, 47998);
        probe.waitForConnected(1000);
        local = probe.localAddress();
    }

    for (const QNetworkInterface& nic : QNetworkInterface::allInterfaces()) {
        for (const QNetworkAddressEntry& entry : nic.addressEntries()) {
            if (!local.isNull() && entry.ip().isEqual(local, QHostAddress::TolerantConversion)) {
                via = nic.name().toUtf8() + " (" + kindOf(nic) + ")";
                s_Link = linkOf(nic);
            }
        }
    }

    if (s_Link == CHROME_TAILSCALE && tailscaleRelays(host)) {
        s_Relayed = true;
        via += ", relayed";
    }
    SDL_snprintf(s_Path, sizeof(s_Path), "%s via %s", host.toUtf8().constData(), via.constData());
    SDL_LogInfo(SDL_LOG_CATEGORY_APPLICATION, "Network path: %s", s_Path);
}
