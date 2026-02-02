// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'store_config.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class StoreConfigAdapter extends TypeAdapter<StoreConfig> {
  @override
  final int typeId = 2;

  @override
  StoreConfig read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return StoreConfig(
      id: fields[0] as String,
      name: fields[1] as String,
      scriptUrl: fields[2] as String,
    );
  }

  @override
  void write(BinaryWriter writer, StoreConfig obj) {
    writer
      ..writeByte(3)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.name)
      ..writeByte(2)
      ..write(obj.scriptUrl);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is StoreConfigAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
