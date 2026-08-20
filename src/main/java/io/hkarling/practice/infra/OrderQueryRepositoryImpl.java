package io.hkarling.practice.infra;

import static io.hkarling.practice.domain.QOrder.order;

import com.querydsl.jpa.impl.JPAQueryFactory;
import io.hkarling.practice.domain.Order;
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
}
