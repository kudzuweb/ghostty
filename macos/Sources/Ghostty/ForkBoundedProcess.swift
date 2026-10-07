import Darwin
import Foundation

/// The independent supervisor retains an inherited lease lock until mutation children
/// are reaped and their remaining process group is killed, even when Ghostty crashes.
enum ForkBoundedProcess {
    struct Result { let status: Int32; let output: String? }
    static func run(_ path: String, _ arguments: [String], timeout: TimeInterval = 15,
                    inheritedLockFD: Int32 = -1) -> Result {
        let supervisor = #"""
        use strict; use POSIX (); use Time::HiRes ();
        my $timeout = shift @ARGV;
        my $child = 0;
        my $cleanup = sub {
            return unless $child > 0;
            kill('TERM', -$child); Time::HiRes::sleep(0.1);
            kill('KILL', -$child); kill('KILL', $child); waitpid($child, 0);
        };
        $SIG{TERM} = sub { $cleanup->(); exit 124; };
        $child = fork(); exit 125 unless defined $child;
        if ($child == 0) {
            $SIG{TERM} = 'DEFAULT';
            POSIX::setpgid(0, 0) == 0 or exit 125;
            exec { $ARGV[0] } @ARGV; exit 125;
        }
        my $deadline = Time::HiRes::time() + $timeout;
        while (waitpid($child, POSIX::WNOHANG()) == 0) {
            if (Time::HiRes::time() >= $deadline) { $cleanup->(); exit 124; }
            Time::HiRes::sleep(0.025);
        }
        my $status = $?;
        kill('KILL', -$child);
        # fd 0 (the optional inherited flock) stays open through all cleanup above.
        exit(($status & 127) ? 128 + ($status & 127) : $status >> 8);
        """#
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = ["-e", supervisor, "\(max(timeout, 0.1))", path] + arguments
        var inherited: FileHandle?
        if inheritedLockFD >= 0 {
            let duplicate = dup(inheritedLockFD)
            guard duplicate >= 0 else { return Result(status: -1, output: nil) }
            inherited = FileHandle(fileDescriptor: duplicate, closeOnDealloc: true)
            process.standardInput = inherited
        } else { process.standardInput = FileHandle.nullDevice }
        defer { try? inherited?.close() }
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("ghostty-command-\(UUID())")
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil,
                                             attributes: [.posixPermissions: 0o600]),
              let output = try? FileHandle(forWritingTo: outputURL) else { return Result(status: -1, output: nil) }
        defer { try? output.close(); try? FileManager.default.removeItem(at: outputURL) }
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return Result(status: -1, output: nil) }
        // Timeout lives in the supervisor, rather than depending on the app surviving.
        process.waitUntilExit()
        let data = try? Data(contentsOf: outputURL)
        let status: Int32 = process.terminationStatus == 124 ? -2 : process.terminationStatus
        return Result(status: status, output: data.flatMap { String(data: $0, encoding: .utf8) })
    }
}
