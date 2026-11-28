// SPDX-License-Identifier: GPL-3.0-only
// Independent command-line reader; the GUI communicates via files/stdout.
#include <MKD/mkd.hpp>
#include <charconv>
#include <iostream>
#include <string_view>
#include <filesystem>

int main(int argc, char** argv) {
    if (argc < 3) return 2;
    try {
        const std::string_view action(argv[1]);
        auto product = MKD::DictionaryProduct::openAtPath(std::filesystem::path(argv[2]));
        if (!product) { std::cerr << product.error() << '\n'; return 1; }
        const auto* dictionary = product->findContent("DAIJISEN.J");
        if (!dictionary || !dictionary->entries() || dictionary->headlines().size() < 2) {
            std::cerr << "Unsupported dictionary format\n"; return 1;
        }
        if (action == "probe" && argc == 3) {
            std::cout << "DAIJISEN.J" << '\n'; return 0;
        }
        if (action == "index" && argc == 4) {
            auto result = MKD::exportToDirectory(*dictionary, std::filesystem::path(argv[3]),
                MKD::ExportOptions{.resources={MKD::ResourceType::Headlines}, .overwriteExisting=false});
            if (!result || !result->isSuccess() || result->exported != 2) {
                std::cerr << "Headline extraction failed\n"; return 1;
            }
            return 0;
        }
        if (action == "entry" && argc == 4) {
            uint32_t id = 0;
            const std::string_view input(argv[3]);
            auto [end, ec] = std::from_chars(input.data(), input.data()+input.size(), id);
            if (ec != std::errc{} || end != input.data()+input.size()) return 2;
            auto article = dictionary->entryUtf8ById(id);
            if (!article) { std::cerr << article.error() << '\n'; return 1; }
            std::cout << *article;
            return std::cout ? 0 : 1;
        }
        return 2;
    } catch (const std::exception& e) { std::cerr << e.what() << '\n'; return 1; }
}
