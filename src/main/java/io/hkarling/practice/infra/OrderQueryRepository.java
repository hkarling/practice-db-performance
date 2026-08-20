package io.hkarling.practice.infra;

import io.hkarling.practice.domain.Order;
import java.util.List;
import org.springframework.data.domain.Pageable;

public interface OrderQueryRepository {

  List<Order> findAllWithCustomerQuerydsl(Pageable pageable);

}
