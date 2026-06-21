package com.schwab.demo.catalog;

import java.math.BigDecimal;

/**
 * Simple immutable product record. Catalog data is hardcoded/in-memory for
 * this demo - there is no database or external GCP dependency for this service.
 */
public record Product(String id, String name, BigDecimal price, String category) {
}
