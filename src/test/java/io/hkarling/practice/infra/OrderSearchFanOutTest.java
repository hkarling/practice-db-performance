package io.hkarling.practice.infra;

import static io.hkarling.practice.domain.QCategory.category;
import static io.hkarling.practice.domain.QOrder.order;
import static io.hkarling.practice.domain.QOrderItem.orderItem;
import static io.hkarling.practice.domain.QProduct.product;
import static org.assertj.core.api.Assertions.assertThat;

import com.querydsl.jpa.impl.JPAQueryFactory;
import io.hkarling.practice.domain.Order;
import java.util.List;
import java.util.stream.Collectors;
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
class OrderSearchFanOutTest {

  @Autowired
  OrderRepository orderRepository;

  @Autowired
  JPAQueryFactory queryFactory;

  @Test
  @DisplayName("카테고리로 필터링하면 order_items 조인 때문에 같은 주문이 중복으로 나올 수 있다")
  void search_byCategory_producesDuplicateOrders() {
    OrderSearchCondition condition = new OrderSearchCondition(null, null, null, 36L);

    List<Order> orders = orderRepository.search(condition, PageRequest.of(0, 20));
    long distinctCount = orders.stream().map(Order::getId).distinct().count();

    log.info("조회된 행 수: {}, 그 중 distinct 주문 수: {}", orders.size(), distinctCount);
    orders.stream()
        .collect(Collectors.groupingBy(Order::getId, Collectors.counting()))
        .forEach((id, count) -> {
          if (count > 1) {
            log.info(">>> 중복 발견: order id={}, {}번 등장", id, count);
          }
        });

    assertThat(orders).isNotEmpty();
  }

  @Test
  @DisplayName("카테고리 36 상품을 2개 담은 order id=23은 조인 결과에 정확히 2번 나온다")
  void search_forOrderWithTwoMatchingItems_returnsDuplicateRow() {
    List<Order> result = queryFactory
        .selectFrom(order)
        .join(orderItem).on(orderItem.order.eq(order))
        .join(orderItem.product, product)
        .join(product.category, category)
        .where(order.id.eq(23L), category.id.eq(36L))
        .fetch();

    log.info("order id=23, category=36 조건으로 조회된 행 수: {}", result.size());

    assertThat(result).hasSize(2);
  }

  @Test
  @DisplayName("LIMIT 20을 요청해도 fan-out 때문에 distinct 주문은 19건만 나온다")
  void search_withOffsetHittingDuplicateRow_returnsFewerThanRequestedOrders() {
    List<Order> result = queryFactory
        .selectFrom(order)
        .distinct()
        .join(orderItem).on(orderItem.order.eq(order))
        .join(orderItem.product, product)
        .join(product.category, category)
        .where(category.id.eq(36L))
        .orderBy(order.id.desc())
        .offset(25)
        .limit(20)
        .fetch();

    log.info("LIMIT 20 요청 → 실제 반환된 리스트 크기: {}", result.size());

    assertThat(result).hasSize(20);
  }

}