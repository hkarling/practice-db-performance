package io.hkarling.practice.infra;

import static org.assertj.core.api.Assertions.assertThat;

import io.hkarling.practice.domain.Order;
import java.util.List;
import lombok.extern.slf4j.Slf4j;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.transaction.annotation.Transactional;

@Slf4j
@SpringBootTest
@Transactional
class CursorPaginationTest {

  @Autowired
  OrderRepository orderRepository;

  @Test
  @DisplayName("커서로 다음 페이지를 이어가면 중복/누락 없이 연속된 결과가 나온다")
  void findNextPage_thenFollowCursor_returnsContinuousResults() {
    List<Order> firstPage = orderRepository.findNextPage(null, 20);
    Long lastIdOfFirstPage = firstPage.get(firstPage.size() - 1).getId();
    log.info("1페이지 마지막 id: {}", lastIdOfFirstPage);

    List<Order> secondPage = orderRepository.findNextPage(lastIdOfFirstPage, 20);
    Long firstIdOfSecondPage = secondPage.get(0).getId();
    log.info("2페이지 첫 id: {}", firstIdOfSecondPage);

    assertThat(firstPage).hasSize(20);
    assertThat(secondPage).hasSize(20);
    // 1페이지 마지막 id보다 2페이지 첫 id가 정확히 1 작아야 함(연속, 중복/누락 없음)
    assertThat(firstIdOfSecondPage).isEqualTo(lastIdOfFirstPage - 1);
  }
}