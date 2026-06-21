package com.schwab.demo.orders;

import java.time.Instant;
import java.util.List;
import java.util.concurrent.ThreadLocalRandom;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RestController;

@RestController
public class OrderController {

    private static final Logger log = LoggerFactory.getLogger(OrderController.class);

    private final OrderRepository repository;

    public OrderController(OrderRepository repository) {
        this.repository = repository;
    }

    @GetMapping("/api/orders")
    public List<Order> listOrders() {
        return repository.findAll();
    }

    @PostMapping("/api/orders")
    public ResponseEntity<Order> createOrder(@RequestBody OrderRequest request) {
        maybeLogSimulatedFailure();
        Order order = new Order(request.product(), request.quantity(), "CREATED", Instant.now());
        Order saved = repository.save(order);
        return ResponseEntity.status(HttpStatus.CREATED).body(saved);
    }

    @GetMapping("/api/orders/{id}")
    public ResponseEntity<Order> getOrder(@PathVariable Long id) {
        return repository.findById(id)
                .map(ResponseEntity::ok)
                .orElseGet(() -> ResponseEntity.notFound().build());
    }

    private void maybeLogSimulatedFailure() {
        // Demo-data generation only: roughly 1-in-20 order creations emit an ERROR
        // log even though the order is still created successfully and a normal
        // 201 is returned. This exists purely so downstream BigQuery error-rate
        // queries/dashboards have non-zero data to chart - no real failure occurs.
        if (ThreadLocalRandom.current().nextInt(20) == 0) {
            log.error("simulated order processing failure (demo data generation only)");
        }
    }
}
