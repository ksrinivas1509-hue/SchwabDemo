package com.schwab.demo.orders;

/**
 * Request body for POST /api/orders: {"product": "...", "quantity": N}
 */
public record OrderRequest(String product, int quantity) {
}
