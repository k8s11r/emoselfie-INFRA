"""격리된 k3d에서만 실행: 테스트 사용자와 방을 생성하고 3라운드를 진행한다."""

import argparse
import asyncio
import ssl
from contextlib import AsyncExitStack
from pathlib import Path

import aiohttp
import httpx
import socketio


async def run(args):
    context = ssl.create_default_context(cafile=args.ca)
    image = await asyncio.to_thread(Path(args.image).read_bytes)
    assert image.startswith(b"\xff\xd8"), "JPEG fixture required"
    sockets = []
    async with AsyncExitStack() as stack:
        clients = [
            await stack.enter_async_context(
                httpx.AsyncClient(
                    base_url=args.url,
                    verify=context,
                    headers={"Origin": args.url},
                    timeout=30,
                )
            )
            for _ in range(2)
        ]
        host, guest = clients
        for client in clients:
            ready = await client.get("/health/ready")
            assert ready.status_code == 200 and ready.json()["inferenceBackend"] == "real"
            session = await client.get("/api/me")
            assert session.status_code == 200
            assert "Secure" in session.headers["set-cookie"]
            assert (await client.get("/api/me")).headers.get("set-cookie") is None
        for _ in range(6):
            if host.cookies.get("es_route") != guest.cookies.get("es_route"):
                break
            guest.cookies.delete("es_route")
            await guest.get("/health/ready")
        assert host.cookies.get("es_route") != guest.cookies.get("es_route"), "Need two Pod routes"
        assert all(cookie.secure for client in clients for cookie in client.cookies.jar)
        refused = await host.patch(
            "/api/me", json={"nickname": "검증방장"}, headers={"Origin": "https://evil.test"}
        )
        assert refused.status_code == 403 and refused.json()["error"]["code"] == "FORBIDDEN_ORIGIN"
        assert (await host.patch("/api/me", json={"nickname": "검증방장"})).status_code == 200
        created = await host.post("/api/rooms", json={"roundCount": 3, "timeLimitSec": 30})
        assert created.status_code == 201
        slug = created.json()["slug"]
        participants = []
        queues = []
        try:
            for client, name, transport in zip(
                clients, ["검증방장", "검증참가"], ["websocket", "polling"], strict=True
            ):
                joined = await client.post(
                    f"/api/rooms/{slug}/participants", json={"nickname": name}
                )
                assert joined.status_code == 201
                participants.append(joined.json()["participantId"])
                session = await stack.enter_async_context(
                    aiohttp.ClientSession(
                        connector=aiohttp.TCPConnector(ssl=context),
                        cookies={cookie.name: cookie.value for cookie in client.cookies.jar},
                    )
                )
                socket = socketio.AsyncClient(http_session=session, reconnection=False)
                sockets.append(socket)
                events = {
                    name: asyncio.Queue()
                    for name in [
                        "room:joined",
                        "round:revealed",
                        "submission:scored",
                        "round:finalized",
                        "game:finished",
                    ]
                }
                queues.append(events)
                for event, queue in events.items():
                    socket.on(event, lambda data, q=queue: q.put_nowait(data))
                await socket.connect(
                    f"{args.url}?slug={slug}",
                    headers={"Origin": args.url},
                    transports=[transport],
                    wait_timeout=20,
                )
                await asyncio.wait_for(events["room:joined"].get(), 20)
                assert socket.transport() == transport
                for _ in range(3):
                    assert (await socket.call("presence:ping", timeout=15))["ok"]
            print(
                "PASS: HTTPS cookies, Origin rejection, distinct Pod routes, WebSocket and polling",
                flush=True,
            )
            assert (await host.post(f"/api/rooms/{slug}/start")).status_code == 200
            for index in range(1, 4):
                rounds = [
                    await asyncio.wait_for(events["round:revealed"].get(), 40) for events in queues
                ]
                assert all(data["index"] == index for data in rounds)
                for client, data in zip(clients, rounds, strict=True):
                    uploaded = await client.post(
                        f"/api/rooms/{slug}/rounds/{data['roundId']}/submissions",
                        files={"image": ("fixture.jpg", image, "image/jpeg")},
                        headers={"X-Capture-Token": data["captureToken"]},
                    )
                    assert uploaded.status_code == 202, f"Upload returned {uploaded.status_code}"
                for client, participant, events in zip(clients, participants, queues, strict=True):
                    async with asyncio.timeout(30):
                        while True:
                            scored = await events["submission:scored"].get()
                            if scored["participantId"] == participant:
                                break
                    assert scored["status"] == "submitted", "Real inference did not score the face"
                    media = await client.get(f"/media/{scored['mediaToken']}")
                    assert media.status_code == 200 and media.content.startswith(b"\xff\xd8")
                    assert media.headers["cache-control"] == "private, no-store"
                    finalized = await asyncio.wait_for(events["round:finalized"].get(), 30)
                    assert len(finalized["results"]) == 2
                skipped = await sockets[0].call(
                    "round:skip", {"roundId": rounds[0]["roundId"]}, timeout=15
                )
                assert skipped["ok"]
                print(f"PASS: round {index}, real inference, media and finalization", flush=True)
            for events in queues:
                await asyncio.wait_for(events["game:finished"].get(), 30)
            print("PASS: three-round game completed across two Pods", flush=True)
        finally:
            await host.post(f"/api/rooms/{slug}/close")
            for socket in sockets:
                if socket.connected:
                    await socket.disconnect()
                await socket.shutdown()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", required=True)
    parser.add_argument("--ca", required=True)
    parser.add_argument("--image", required=True)
    arguments = parser.parse_args()
    asyncio.run(run(arguments))
