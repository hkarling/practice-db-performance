package io.hkarling.practice.infra;

import static org.assertj.core.api.Assertions.assertThat;

import io.hkarling.practice.domain.Order;
import java.util.List;
import lombok.extern.slf4j.Slf4j;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.data.domain.PageRequest;
import org.springframework.transaction.annotation.Transactional;

@Slf4j
@SpringBootTest
@Transactional
class FetchJoinTest {

  @Autowired
  OrderRepository orderRepository;

  @Test
  @DisplayName("fetch join으로 조회하면 customer 접근 시 추가 쿼리가 나가지 않는다")
  void findAllWithCustomer_thenAccessCustomer_noAdditionalQueries() {
    log.info("========== 1. fetch join으로 주문 목록 조회 ==========");
    List<Order> orders = orderRepository.findAllWithCustomer(PageRequest.of(0, 20));

    int i = 0;
    for (Order order : orders) {
      log.info("---------- 2-{}. order id={}의 customer 접근 (이미 로딩되어 있어야 함) ----------",
          ++i, order.getId());
      assertThat(order.getCustomer().getName()).isNotBlank();
    }
  }
}