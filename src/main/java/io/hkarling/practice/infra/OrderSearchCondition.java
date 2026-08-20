package io.hkarling.practice.infra;

import io.hkarling.practice.domain.OrderStatus;
import java.time.OffsetDateTime;

public record OrderSearchCondition(
    OrderStatus status,
    OffsetDateTime from,
    OffsetDateTime to,
    Long categoryId
) {

}
