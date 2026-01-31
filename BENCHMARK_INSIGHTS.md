The main difference in performance is via the OCR_LANG_CORRECTION option.

OCR_LANG_CORRECTION is an Apple Vision OCR feature that basically runs a second stage and tries to correct things like similar looking characters (l, 1, etc) or fill in gaps in words.

**Splitting PDFs into pages using jpg, currently approximately doubles their size. This means for 100 GB of PDFs we should expect 200 GB of throughput in the vision service**

## With OCR_LANG_CORRECTION=true:

### Throughput:

~ 10 pages per second
~ 2.6 MB per second

or ~ 9.3 GB per hour
or ~ 4.4 days per TB

## With OCR_LANG_CORRECTION=false:

### Throughput:

~ 30 pages per second
~ 7.5 MB per second

or ~ 27 GB per hour
or 1,5 days per TB
