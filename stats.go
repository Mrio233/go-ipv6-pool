package main

import (
	"log"
	"runtime"
	"sync/atomic"
	"time"
)

// 统计信息
var (
	totalConnections   int64
	activeConnections  int64
	failedConnections  int64
	totalBytesSent     int64
	totalBytesReceived int64
)

// startStatsMonitor 启动统计监控
func startStatsMonitor() {
	go func() {
		ticker := time.NewTicker(30 * time.Second)
		defer ticker.Stop()

		for range ticker.C {
			var m runtime.MemStats
			runtime.ReadMemStats(&m)

			log.Printf("[Stats] Active: %d, Total: %d, Failed: %d, Goroutines: %d",
				atomic.LoadInt64(&activeConnections),
				atomic.LoadInt64(&totalConnections),
				atomic.LoadInt64(&failedConnections),
				runtime.NumGoroutine())

			log.Printf("[Memory] Alloc: %d MB, Sys: %d MB, NumGC: %d",
				m.Alloc/1024/1024,
				m.Sys/1024/1024,
				m.NumGC)
		}
	}()
}

// incrementConn 增加连接计数
func incrementConn() {
	atomic.AddInt64(&totalConnections, 1)
	atomic.AddInt64(&activeConnections, 1)
}

// decrementConn 减少活跃连接计数
func decrementConn() {
	atomic.AddInt64(&activeConnections, -1)
}

// incrementFailed 增加失败计数
func incrementFailed() {
	atomic.AddInt64(&failedConnections, 1)
}

// addBytes 添加传输字节数
func addBytes(sent, received int64) {
	atomic.AddInt64(&totalBytesSent, sent)
	atomic.AddInt64(&totalBytesReceived, received)
}
