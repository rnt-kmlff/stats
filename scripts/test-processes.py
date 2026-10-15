#!/usr/bin/env python3
"""Compile and run deterministic process/history/alert tests; no live stress."""
import pathlib, platform, subprocess, tempfile
root = pathlib.Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="stats-process-tests-") as output:
    output = pathlib.Path(output)
    subprocess.run(["swiftc", "-parse-as-library", "-module-cache-path", str(output / "module-cache"),
                    "-target", f"{platform.machine()}-apple-macos12.0", "-O",
                    str(root / "Stats/Views/ProcessMonitorCore.swift"),
                    str(root / "Stats/Views/CodexChatAttributionCore.swift"),
                    str(root / "Stats/Views/CodexChatAttribution.swift"),
                    str(root / "Stats/Views/ProcessMemoryCollector.swift"),
                    str(root / "Tests/Processes/ChatMetadataTests.swift"),
                    str(root / "Tests/Processes/ProcessInspectionTests.swift"),
                    str(root / "Tests/Processes/ProcessesTests.swift"), "-o", str(output / "process-tests")], check=True)
    subprocess.run([str(output / "process-tests")], check=True)
