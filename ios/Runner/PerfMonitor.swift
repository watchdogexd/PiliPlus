import Foundation

// Lightweight, App-Store-safe process metrics for development performance monitoring.
//
// CPU and memory come from mach task introspection; thermalState is a public proxy for sustained
// CPU+GPU load (there is NO public API for GPU utilization % on iOS — use Xcode's GPU gauge or
// Instruments' Metal System Trace for that). Sampling is cheap (a couple of mach calls), so it's
// safe to poll every couple of seconds from Dart while a video is playing.
enum PerfMonitor {
  // Whole-process CPU usage as a percentage of one core (so >100% on multi-core under load).
  private static func cpuPercent() -> Double {
    var threadList: thread_act_array_t?
    var threadCount: mach_msg_type_number_t = 0
    guard task_threads(mach_task_self_, &threadList, &threadCount) == KERN_SUCCESS,
          let threads = threadList
    else { return -1 }
    defer {
      vm_deallocate(
        mach_task_self_, vm_address_t(UInt(bitPattern: threads)),
        vm_size_t(Int(threadCount) * MemoryLayout<thread_t>.stride))
    }

    // THREAD_BASIC_INFO_COUNT is a sizeof-based macro that Swift doesn't import; compute it.
    let basicInfoCount = mach_msg_type_number_t(
      MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
    var total: Double = 0
    for i in 0..<Int(threadCount) {
      var info = thread_basic_info()
      var count = basicInfoCount
      let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
          thread_info(threads[i], thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
        }
      }
      if kr == KERN_SUCCESS, info.flags & TH_FLAGS_IDLE == 0 {
        total += Double(info.cpu_usage) / Double(TH_USAGE_SCALE) * 100.0
      }
    }
    return total
  }

  // Real physical memory footprint (what iOS uses for jetsam/OOM decisions), in MB.
  private static func memoryMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    guard kr == KERN_SUCCESS else { return -1 }
    return Double(info.phys_footprint) / 1024.0 / 1024.0
  }

  private static func thermal() -> String {
    switch ProcessInfo.processInfo.thermalState {
    case .nominal: return "nominal"
    case .fair: return "fair"
    case .serious: return "serious"
    case .critical: return "critical"
    @unknown default: return "?"
    }
  }

  // One formatted sample line, e.g. "cpu=84% mem=312MB thermal=fair cores=6".
  static func sample() -> String {
    return String(
      format: "cpu=%.0f%% mem=%.0fMB thermal=%@ cores=%d",
      cpuPercent(), memoryMB(), thermal(), ProcessInfo.processInfo.activeProcessorCount)
  }
}
