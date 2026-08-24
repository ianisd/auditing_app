// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'plu_mapping.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class PluMappingAdapter extends TypeAdapter<PluMapping> {
  @override
  final int typeId = 10;

  @override
  PluMapping read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return PluMapping(
      csvPlu: fields[0] as String,
      csvDescription: fields[1] as String,
      correctPlu: fields[2] as String,
      productName: fields[3] as String,
      supplierId: fields[4] as String,
      createdAt: fields[5] as DateTime,
      confidence: fields[6] as int,
    );
  }

  @override
  void write(BinaryWriter writer, PluMapping obj) {
    writer
      ..writeByte(7)
      ..writeByte(0)
      ..write(obj.csvPlu)
      ..writeByte(1)
      ..write(obj.csvDescription)
      ..writeByte(2)
      ..write(obj.correctPlu)
      ..writeByte(3)
      ..write(obj.productName)
      ..writeByte(4)
      ..write(obj.supplierId)
      ..writeByte(5)
      ..write(obj.createdAt)
      ..writeByte(6)
      ..write(obj.confidence);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PluMappingAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
