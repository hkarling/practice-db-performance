package io.hkarling.practice.infra;

import static org.assertj.core.api.Assertions.assertThat;

import io.hkarling.practice.domain.Order;
import lombok.extern.slf4j.Slf4j;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.data.domain.Page;
import org.springframework.data.domain.PageRequest;
import org.springframework.transaction.annotation.Transactional;

@Slf4j
@SpringBootTest
@Transactional
class NPlusOneTest {

  @Autowired
  OrderRepository orderRepository;

  @Test
  @DisplayName("주문 목록 조회 후 각 주문의 customer에 접근하면 N+1 쿼리가 발생한다")
  void findOrders_thenAccessLazyCustomer_triggersNPlusOneQueries() {
    log.info("========== 1. 주문 목록 조회 (쿼리 1번) ==========");
    Page<Order> orders = orderRepository.findAll(PageRequest.of(0, 20));

    int i = 0;
    for (Order order : orders) {
      log.info("---------- 2-{}. order id={}의 customer 접근 (LAZY 초기화 시도) ----------", ++i, order.getId());
      assertThat(order.getCustomer().getName()).isNotBlank();
    }
  }
}