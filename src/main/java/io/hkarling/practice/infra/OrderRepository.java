package io.hkarling.practice.infra;

import io.hkarling.practice.domain.Order;
import java.util.List;
import org.springframework.data.domain.Pageable;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;

public interface OrderRepository extends JpaRepository<Order, Long> {

  @Query("SELECT o FROM Order o JOIN FETCH o.customer ORDER BY o.id DESC")
  List<Order> findAllWithCustomer(Pageable pageable);
}
