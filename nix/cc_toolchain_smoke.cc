#include <iostream>
#include <vector>

int main() {
    const std::vector<const char *> words = {"portable", " toolchain"};
    for (const char *word : words) {
        std::cout << word;
    }
    std::cout << '\n';
    return 0;
}
