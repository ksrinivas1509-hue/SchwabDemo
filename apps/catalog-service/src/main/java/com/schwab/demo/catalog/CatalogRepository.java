package com.schwab.demo.catalog;

import java.math.BigDecimal;
import java.util.List;
import java.util.Optional;

import org.springframework.stereotype.Repository;

/**
 * In-memory, hardcoded product catalog. No external GCP dependencies -
 * this service is intentionally stateless.
 */
@Repository
public class CatalogRepository {

    private final List<Product> products = List.of(
            new Product("1", "Wireless Mouse", new BigDecimal("24.99"), "electronics"),
            new Product("2", "Mechanical Keyboard", new BigDecimal("79.50"), "electronics"),
            new Product("3", "Standing Desk", new BigDecimal("349.00"), "furniture"),
            new Product("4", "Ceramic Coffee Mug", new BigDecimal("12.00"), "kitchen"),
            new Product("5", "Noise-Cancelling Headphones", new BigDecimal("199.99"), "electronics")
    );

    public List<Product> findAll() {
        return products;
    }

    public Optional<Product> findById(String id) {
        return products.stream().filter(p -> p.id().equals(id)).findFirst();
    }
}
