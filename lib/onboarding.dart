import 'package:flutter/material.dart';
import 'package:flutter_tuner/onboarding_widget.dart';
import 'package:go_router/go_router.dart';
import 'package:smooth_page_indicator/smooth_page_indicator.dart';

class OnBoardingScreen extends StatefulWidget {
  const OnBoardingScreen({super.key});

  @override
  State<OnBoardingScreen> createState() => _OnBoardingScreenState();
}

class _OnBoardingScreenState extends State<OnBoardingScreen> {
  PageController controller = PageController();

  final List<Map<String, String>> pageContent = [
    {
      "title": "Tune Every String",
      "description":
          "Select your instrument — guitar, cello, bass, or violin — and get ready for perfect pitch every time.",
      "file_name": "first",
    },
    {
      "title": "Visualize Your Sound",
      "description":
          "See your notes on a dynamic graph. Track pitch changes, fine-tune in real-time, and adjust the reference tone to your preference.",
      "file_name": "second",
    },
    {
      "title": "Track Your Progress",
      "description":
          "Review your pitch history over time. Improve accuracy, monitor consistency, and master every string like a pro.",
      "file_name": "third",
    },
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: PageView.builder(
                itemCount: pageContent.length,
                controller: controller,
                itemBuilder: (context, index) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 30.0),
                    child: OnBoardingPage(
                      title: pageContent[index]['title']!,
                      description: pageContent[index]['description']!,
                      fileName: pageContent[index]['file_name']!,
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 50.0, vertical: 30.0),
        child: Row(
          children: [
            SmoothPageIndicator(
              controller: controller,
              count: pageContent.length,
              effect: const ExpandingDotsEffect(
                activeDotColor: Colors.blue,
                dotColor: Color.fromARGB(255, 224, 224, 224),
                dotHeight: 10,
              ),
            ),
            const Spacer(),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                shape: const CircleBorder(),
                padding: const EdgeInsets.all(16),
                backgroundColor: Colors.blue,
              ),
              onPressed: () {
                if (controller.page != null) {
                  if (controller.page! == pageContent.length - 1) {
                    context.pushReplacement('/home');
                  } else {
                    int nextPage = (controller.page! + 1).toInt();
                    controller.animateToPage(
                      nextPage,
                      duration: const Duration(milliseconds: 300),
                      curve: Curves.easeInOut,
                    );
                  }
                }
              },
              child: const Icon(Icons.arrow_forward, color: Colors.white),
            ),
          ],
        ),
      ),
    );
  }
}
