package io.hkarling.practice.infra;

import io.hkarling.practice.domain.Order;
import java.util.List;
import org.springframework.data.domain.Pageable;

public interface OrderQueryRepository {

  List<Order> findAllWithCustomerQuerydsl(Pageable pageable);

  List<Order> search(OrderSearchCondition condition, Pageable pageable);

  List<Order> findNextPage(Long cursorId, int size);
}
