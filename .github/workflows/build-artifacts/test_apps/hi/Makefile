 CC = gcc
CFLAGS = -Wall -Werror
TARGET = hi
SOURCE = hi.c

all: $(TARGET)

$(TARGET): $(SOURCE)
	echo "Building hi"
	mkdir -p build
	$(CC) $(CFLAGS) -o build/$(TARGET) $(SOURCE)

clean:
	echo "Cleaning up"
	rm -rf build

.PHONY: all clean