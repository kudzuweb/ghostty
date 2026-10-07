import Foundation
let result = ForkBoundedProcess.run(CommandLine.arguments[1], [], timeout: 0.25)
precondition(result.status == -2, "hung command must return deadline status")
print("Bounded process timeout check passed")
