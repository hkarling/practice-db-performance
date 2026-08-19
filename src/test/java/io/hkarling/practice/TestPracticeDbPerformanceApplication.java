package io.hkarling.practice;

import org.springframework.boot.SpringApplication;

public class TestPracticeDbPerformanceApplication {

	public static void main(String[] args) {
		SpringApplication.from(Application::main).with(TestcontainersConfiguration.class).run(args);
	}

}
