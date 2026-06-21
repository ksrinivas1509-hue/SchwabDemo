package com.schwab.demo.catalog;

import java.util.List;
import java.util.concurrent.ThreadLocalRandom;
import java.util.concurrent.atomic.AtomicLong;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

@RestController
public class CatalogController {

    private static final Logger log = LoggerFactory.getLogger(CatalogController.class);

    private final CatalogRepository repository;

    // Demo-data-generation only: counts requests to /api/catalog so we can emit
    // a simulated failure on roughly 1-in-20 of them, purely to give downstream
    // BigQuery error-rate queries some non-zero data to chart. No real failure occurs.
    private final AtomicLong requestCounter = new AtomicLong();

    public CatalogController(CatalogRepository repository) {
        this.repository = repository;
    }

    @GetMapping("/api/catalog")
    public List<Product> listCatalog() {
        maybeLogSimulatedFailure();
        return repository.findAll();
    }

    @GetMapping("/api/catalog/{id}")
    public ResponseEntity<Product> getProduct(@PathVariable String id) {
        return repository.findById(id)
                .map(ResponseEntity::ok)
                .orElseGet(() -> ResponseEntity.notFound().build());
    }

    /**
     * Busy-sleeps for the requested number of milliseconds to generate artificial
     * CPU/latency load on demand. Used to manually trigger HPA scale-out during
     * autoscaling demos, since the hardcoded catalog data is otherwise too cheap
     * to serve to meaningfully load the CPU.
     */
    @GetMapping("/api/catalog/stress")
    public String stress(@RequestParam(name = "ms", defaultValue = "500") long ms) {
        long deadline = System.nanoTime() + (ms * 1_000_000L);
        long x = 0;
        while (System.nanoTime() < deadline) {
            // Busy-loop (rather than Thread.sleep) so this actually burns CPU cycles
            // for HPA's cpu-utilization metric to pick up.
            x += 1;
        }
        return "stressed for " + ms + "ms (iterations=" + x + ")";
    }

    private void maybeLogSimulatedFailure() {
        long count = requestCounter.incrementAndGet();
        // Roughly 1-in-20 requests: log an ERROR but still return 200 below.
        // This is demo-data generation only - no real lookup failure happens -
        // it exists solely so downstream BigQuery error-rate queries have
        // non-zero data to chart.
        if (ThreadLocalRandom.current().nextInt(20) == 0) {
            log.error("simulated catalog lookup failure (demo data generation only, request #{})", count);
        }
    }
}
