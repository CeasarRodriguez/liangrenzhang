import 'package:flutter/material.dart';

import 'budget.dart';

class Category {
  const Category(this.name, this.icon, this.color);

  final String name;
  final IconData icon;
  final Color color;
}

const expenseCategories = [
  Category('餐饮', Icons.restaurant_rounded, Color(0xFFFF8A65)),
  Category('交通', Icons.directions_bus_rounded, Color(0xFF4FC3F7)),
  Category('购物', Icons.shopping_bag_rounded, Color(0xFFF06292)),
  Category('日用', Icons.local_grocery_store_rounded, Color(0xFF81C784)),
  Category('娱乐', Icons.sports_esports_rounded, Color(0xFFBA68C8)),
  Category('医疗', Icons.local_hospital_rounded, Color(0xFFE57373)),
  Category('人情', Icons.card_giftcard_rounded, Color(0xFFFFB74D)),
  Category('居住', Icons.home_rounded, Color(0xFF7986CB)),
  Category('其他', Icons.more_horiz_rounded, Color(0xFF90A4AE)),
];

const incomeCategories = [
  Category('工资', Icons.work_rounded, Color(0xFF4DB6AC)),
  Category('奖金', Icons.emoji_events_rounded, Color(0xFFFFD54F)),
  Category('兼职', Icons.handyman_rounded, Color(0xFF64B5F6)),
  Category('理财', Icons.trending_up_rounded, Color(0xFFAED581)),
  Category('其他', Icons.more_horiz_rounded, Color(0xFF90A4AE)),
];

List<Category> categoriesFor(String type) => type == typeIncome ? incomeCategories : expenseCategories;

Category categoryOf(String type, String name) =>
    categoriesFor(type).where((c) => c.name == name).firstOrNull ?? categoriesFor(type).last;
