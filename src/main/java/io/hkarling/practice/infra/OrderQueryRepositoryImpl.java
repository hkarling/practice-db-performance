package io.hkarling.practice.infra;

import static io.hkarling.practice.domain.QCustomer.customer;
import static io.hkarling.practice.domain.QOrder.order;
import static io.hkarling.practice.domain.QProduct.product;

import com.querydsl.core.types.dsl.BooleanExpression;
import com.querydsl.jpa.JPAExpressions;
import com.querydsl.jpa.impl.JPAQueryFactory;
import io.hkarling.practice.domain.Order;
import io.hkarling.practice.domain.OrderStatus;
import io.hkarling.practice.domain.QOrderItem;
import java.time.OffsetDateTime;
import java.util.List;
import lombok.RequiredArgsConstructor;
import org.springframework.data.domain.Pageable;

@RequiredArgsConstructor
public class OrderQueryRepositoryImpl implements OrderQueryRepository {

  private final JPAQueryFactory queryFactory;

  @Override
  public List<Order> findAllWithCustomerQuerydsl(Pageable pageable) {
    return queryFactory
        .selectFrom(order)
        .join(order.customer).fetchJoin()
        .orderBy(order.id.desc())
        .offset(pageable.getOffset())
        .limit(pageable.getPageSize())
        .fetch();
  }

  @Override
  public List<Order> search(OrderSearchCondition condition, Pageable pageable) {
    return queryFactory
        .selectFrom(order)
        .join(order.customer, customer).fetchJoin()
        .where(
            statusEq(condition.status()),
            orderedAtBetween(condition.from(), condition.to()),
            categoryExists(condition.categoryId())
        )
        .orderBy(order.id.desc())
        .offset(pageable.getOffset())
        .limit(pageable.getPageSize())
        .fetch();
  }

  @Override
  public List<Order> findNextPage(Long cursorId, int size) {
    return queryFactory
        .selectFrom(order)
        .join(order.customer, customer).fetchJoin()
        .where(cursorId != null ? order.id.lt(cursorId) : null)
        .orderBy(order.id.desc())
        .limit(size)
        .fetch();
  }

  private BooleanExpression statusEq(OrderStatus status) {
    return status != null ? order.status.eq(status) : null;
  }

  private BooleanExpression orderedAtBetween(OffsetDateTime from, OffsetDateTime to) {
    if (from != null && to != null) {
      return order.orderedAt.between(from, to);
    }
    if (from != null) {
      return order.orderedAt.goe(from);
    }
    if (to != null) {
      return order.orderedAt.loe(to);
    }
    return null;
  }

  private BooleanExpression categoryExists(Long categoryId) {
    if (categoryId == null) {
      return null;
    }
    QOrderItem oi = new QOrderItem("oi");
    return JPAExpressions.selectOne()
        .from(oi)
        .join(oi.product, product)
        .where(oi.order.eq(order), product.category.id.eq(categoryId))
        .exists();
  }
}
