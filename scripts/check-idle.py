#!/usr/bin/env python3
"""Checks an already-started server with --idle-unload-minutes 0.05, then stops its exact PID."""
import json
import os
from pathlib import Path
import signal
import subprocess
import time

proof = Path(__file__).resolve().parents[1] / 'proof'
pid = int((proof / 'idle-server.pid').read_text())
key = (Path.home() / '.sensenova/api-key').read_text().strip()
config = 'header = "Authorization: Bearer ' + key + '"\n'
base = 'http://127.0.0.1:8003'

def get_health():
    result = subprocess.run(['curl', '-sf', base + '/health'], capture_output=True, text=True)
    return json.loads(result.stdout) if result.returncode == 0 else None

results = {}
try:
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        health = get_health()
        if health:
            results['initial'] = health; break
        time.sleep(0.2)
    assert results.get('initial', {}).get('model_loaded') is True
    initial_memory = subprocess.run(['footprint', '-p', str(pid), '-f', 'bytes', '--noCategories'], text=True, capture_output=True)
    (proof / 'startup-footprint-bytes.txt').write_text(initial_memory.stdout + initial_memory.stderr)
    start = time.monotonic()
    while time.monotonic() - start < 25:
        health = get_health()
        if health and not health['model_loaded']:
            results['after_idle'] = health; results['idle_observed_seconds'] = time.monotonic() - start; break
        time.sleep(0.5)
    assert 'after_idle' in results
    unloaded_memory = subprocess.run(['footprint', '-p', str(pid), '-f', 'bytes', '--noCategories'], text=True, capture_output=True)
    (proof / 'unloaded-footprint-bytes.txt').write_text(unloaded_memory.stdout + unloaded_memory.stderr)
    body = {'messages': [{'role': 'user', 'content': 'Say hello.'}], 'max_tokens': 8}
    path = proof / 'idle-reload-request.json'; path.write_text(json.dumps(body))
    start = time.monotonic()
    result = subprocess.run(['curl', '-sf', '--config', '-', '-H', 'Content-Type: application/json', '--data-binary', '@' + str(path), base + '/v1/chat/completions'], input=config, capture_output=True, text=True, check=True)
    results['reload_seconds'] = time.monotonic() - start
    (proof / 'idle-reload-answer.json').write_text(result.stdout)
    results['after_reload'] = get_health()
    assert results['after_reload']['model_loaded'] is True
    # Shut down during a live streamed job; a complete SSE answer must still arrive.
    body['messages'][0]['content'] = 'Count the integers from 1 to 200, separated by commas.'
    body['max_tokens'] = 128; body['stream'] = True
    path.write_text(json.dumps(body))
    process = subprocess.Popen(['curl', '-NsS', '--max-time', '90', '--config', '-', '-H', 'Content-Type: application/json', '--data-binary', '@' + str(path), base + '/v1/chat/completions'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    process.stdin.write(config); process.stdin.close()
    sent_signal = False; content = []
    start = time.monotonic()
    for line in process.stdout:
        content.append(line)
        if '"content"' in line and not sent_signal:
            os.kill(pid, signal.SIGTERM); sent_signal = True
    process.wait(timeout=90)
    text = ''.join(content)
    (proof / 'shutdown-drained-stream.sse').write_text(text)
    results['shutdown_stream_complete'] = sent_signal and '[DONE]' in text and process.returncode == 0
    results['shutdown_drain_seconds'] = time.monotonic() - start
    assert results['shutdown_stream_complete']
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        process_state = subprocess.run(['ps', '-p', str(pid), '-o', 'stat='], capture_output=True, text=True)
        if process_state.returncode != 0 or process_state.stdout.strip().startswith('Z'): break
        time.sleep(0.1)
    assert get_health() is None
    results['port_closed'] = True
finally:
    # Only this recorded PID can be signaled, including when a check fails.
    if not results.get('port_closed'):
        try: os.kill(pid, signal.SIGTERM)
        except ProcessLookupError: pass
    (proof / 'idle-shutdown-results.json').write_text(json.dumps(results, indent=2))
print(json.dumps(results, indent=2))
