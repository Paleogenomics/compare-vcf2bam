#include <stdio.h>
#include <stdlib.h>

unsigned long choose(unsigned int n, unsigned int k) {
    if (k == 0) {
        return 1;
    }
    return (n * choose(n-1, k-1)) / k;
}

unsigned long** init_nCk(unsigned int n) {
    unsigned long** nCk = malloc((n+1) * sizeof(unsigned long*));
    for (int i = 0; i <= n; i++) {
        unsigned long* iCk = malloc((n+1) * sizeof(unsigned long));
        for (int j = 0; j <= n; j++) {
            iCk[j] = choose(i, j);
        }
        nCk[i] = iCk;
    }  
    return nCk;
}

unsigned long retrieve_nCk(unsigned long** nCk, unsigned int n, unsigned int k) {
    if (k > n) {
        fprintf(stderr, "Invalid k = %u; enter k so that k <= n\n", k);
    }
    return *(nCk[n]+k);
}

int destroy_nCk(unsigned long** nCk, unsigned int n) {
    if (!nCk) {
        return 0;
    }
    for (int i = 0; i <= n; i++) {
        free(nCk[i]);
    }
    free(nCk);
    return 0;
}

int main() {
    unsigned long** nCk = init_nCk(20);
    printf("Result for 20 choose 7 is: %lu\n", retrieve_nCk(nCk, 20,7));
    destroy_nCk(nCk, 20);
    return 0;
}