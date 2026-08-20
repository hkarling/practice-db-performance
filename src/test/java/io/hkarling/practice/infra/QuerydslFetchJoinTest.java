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
public class QuerydslFetchJoinTest {

  @Autowired
  OrderRepository orderRepository;

  @Test
  @DisplayName("QueryDSL fetch join도 JPQL fetch join과 동일하게 단일 쿼리로 customer를 채운다")
  void findAllWithCustomerQuerydsl_thenAccessCustomer_noAdditionalQueries() {
    log.info("========== 1. QueryDSL fetch join으로 주문 목록 조회 ==========");
    List<Order> orders = orderRepository.findAllWithCustomerQuerydsl(PageRequest.of(0, 20));

    int i = 0;
    for (Order order : orders) {
      log.info("---------- 2-{}. order id={}의 customer 접근 (이미 로딩되어 있어야 함) ----------",
          ++i, order.getId());
      assertThat(order.getCustomer().getName()).isNotBlank();
    }
  }
}
